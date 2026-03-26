import Foundation

/// Manages the lifecycle of a single fly.io machine for a cloud workspace.
/// Provisions the machine, establishes a `fly proxy` SSH tunnel, probes SSH readiness,
/// then hands off to the existing `WorkspaceRemoteSessionController` via
/// `workspace.configureRemoteConnection()`.
@MainActor
final class FlyMachineController {
    private let api: FlyMachinesAPI
    private weak var workspace: Workspace?
    private var configuration: FlyCloudConfiguration
    private let sshPublicKey: String

    private var proxyProcess: Process?
    private var localSSHPort: Int?
    private var isStopping = false
    private var provisioningTask: Task<Void, Never>?

    init(
        workspace: Workspace,
        configuration: FlyCloudConfiguration,
        apiToken: String,
        sshPublicKey: String
    ) {
        self.workspace = workspace
        self.configuration = configuration
        self.api = FlyMachinesAPI(token: apiToken)
        self.sshPublicKey = sshPublicKey
    }

    deinit {
        provisioningTask?.cancel()
        if let process = proxyProcess, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Public Lifecycle

    func start() {
        guard !isStopping else { return }
        provisioningTask?.cancel()
        provisioningTask = Task { [weak self] in
            await self?.runProvisioning()
        }
    }

    func stop() {
        isStopping = true
        provisioningTask?.cancel()
        provisioningTask = nil
        killProxyProcess()

        guard let workspace, let machineID = configuration.resolvedMachineID else {
            workspace?.cloudMachineState = .stopped
            return
        }
        workspace.cloudMachineState = .stopping
        let api = self.api
        let app = configuration.appName
        Task.detached {
            try? await api.stopMachine(app: app, machineID: machineID)
            await MainActor.run { [weak workspace] in
                workspace?.cloudMachineState = .stopped
            }
        }
    }

    func destroy() {
        isStopping = true
        provisioningTask?.cancel()
        provisioningTask = nil
        killProxyProcess()

        guard let workspace, let machineID = configuration.resolvedMachineID else {
            workspace?.cloudMachineState = .destroyed
            workspace?.cloudConfiguration = nil
            return
        }
        workspace.cloudMachineState = .destroying
        let api = self.api
        let app = configuration.appName
        Task.detached {
            try? await api.destroyMachine(app: app, machineID: machineID, force: true)
            await MainActor.run { [weak workspace] in
                workspace?.cloudMachineState = .destroyed
                workspace?.cloudConfiguration = nil
            }
        }
    }

    // MARK: - Provisioning Flow

    private func runProvisioning() async {
        guard let workspace else { return }
        do {
            try Task.checkCancellation()

            // Step 1: Resolve fly CLI path
            let flyPath = try Self.resolveFlyCLI()

            // Step 2: Create or start the machine
            let machineID: String
            if let existingID = configuration.resolvedMachineID {
                workspace.cloudMachineState = .starting
                try await api.startMachine(app: configuration.appName, machineID: existingID)
                machineID = existingID
            } else {
                workspace.cloudMachineState = .creating
                let machine = try await createMachine()
                machineID = machine.id
                configuration.resolvedMachineID = machineID
                workspace.cloudConfiguration?.resolvedMachineID = machineID
            }

            try Task.checkCancellation()

            // Step 3: Wait for machine to be started
            workspace.cloudMachineState = .starting
            _ = try await api.waitForState(
                app: configuration.appName,
                machineID: machineID,
                state: "started",
                timeout: 60
            )

            try Task.checkCancellation()

            // Step 4: Get machine private IP and launch fly proxy
            workspace.cloudMachineState = .waitingForSSH
            let machine = try await api.getMachine(app: configuration.appName, machineID: machineID)
            let privateIP = machine.privateIp ?? ""
            let port = try await launchFlyProxy(flyPath: flyPath, machineID: machineID, privateIP: privateIP)
            localSSHPort = port

            try Task.checkCancellation()

            // Step 5: Probe SSH readiness
            try await probeSSH(host: "127.0.0.1", port: port, maxAttempts: 30, delaySeconds: 2)

            try Task.checkCancellation()

            // Step 6: Hand off to existing remote session infrastructure
            let remoteConfig = buildRemoteConfiguration(localPort: port)
            workspace.configureRemoteConnection(remoteConfig, autoConnect: true)
            workspace.cloudMachineState = .ready

        } catch is CancellationError {
            // Normal cancellation, don't report error
        } catch {
            workspace.cloudMachineState = .error
            workspace.cloudMachineDetail = error.localizedDescription
        }
    }

    // MARK: - Machine Creation

    private func createMachine() async throws -> FlyMachine {
        // Ensure the fly.io app exists (creates it if not, ignores "already exists")
        try await api.ensureAppExists(name: configuration.appName)

        let spec = configuration.machineSpec

        // If a volume is requested, ensure it exists
        var mounts: [FlyMachineCreateRequest.Config.Mount]?
        if let volumeName = configuration.volumeName {
            let volumeID = try await resolveOrCreateVolume(
                name: volumeName,
                region: spec.region ?? "iad",
                sizeGB: spec.volumeSizeGB ?? 10
            )
            configuration.resolvedVolumeID = volumeID
            await MainActor.run { [weak workspace, volumeID] in
                workspace?.cloudConfiguration?.resolvedVolumeID = volumeID
            }
            mounts = [.init(volume: volumeID, path: "/workspace")]
        }

        let initScript = FlyCloudConfiguration.machineInitScript(
            sshPublicKey: sshPublicKey,
            sshUser: configuration.sshUser
        )

        let request = FlyMachineCreateRequest(
            name: nil,
            region: spec.region,
            config: .init(
                image: spec.image,
                guest: .init(
                    cpuKind: spec.cpuKind,
                    cpus: spec.cpus,
                    memoryMb: spec.memoryMB
                ),
                env: ["CMUX_CLOUD": "1", "SSH_PUBKEY": sshPublicKey],
                init: .init(exec: ["/bin/bash", "-c", initScript]),
                mounts: mounts,
                services: nil
            )
        )

        return try await api.createMachine(app: configuration.appName, config: request)
    }

    private func resolveOrCreateVolume(name: String, region: String, sizeGB: Int) async throws -> String {
        let volumes = try await api.listVolumes(app: configuration.appName)
        if let existing = volumes.first(where: { $0.name == name && $0.attachedMachineId == nil }) {
            return existing.id
        }
        let volume = try await api.createVolume(
            app: configuration.appName,
            request: FlyVolumeCreateRequest(name: name, region: region, sizeGb: sizeGB)
        )
        return volume.id
    }

    // MARK: - Fly Proxy

    private func launchFlyProxy(flyPath: String, machineID: String, privateIP: String) async throws -> Int {
        let localPort = try Self.findAvailablePort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: flyPath)
        // Pass the machine's private IP as remote_host to avoid interactive prompt
        var args = ["proxy", "\(localPort):22"]
        if !privateIP.isEmpty {
            args.append(privateIP)
        }
        args += ["-a", configuration.appName, "-q"]
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
        if let token = api.token as String? {
            process.environment?["FLY_API_TOKEN"] = token
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        proxyProcess = process

        // Give fly proxy a moment to bind
        try await Task.sleep(nanoseconds: 500_000_000)

        guard process.isRunning else {
            throw FlyControllerError.proxyLaunchFailed
        }

        return localPort
    }

    private func killProxyProcess() {
        if let process = proxyProcess, process.isRunning {
            process.terminate()
        }
        proxyProcess = nil
        localSSHPort = nil
    }

    // MARK: - SSH Probe

    private func probeSSH(host: String, port: Int, maxAttempts: Int, delaySeconds: UInt64) async throws {
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            if Self.canConnectTCP(host: host, port: port, timeoutSeconds: 3) {
                return
            }
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
        throw FlyControllerError.sshNotReachable
    }

    private static func canConnectTCP(host: String, port: Int, timeoutSeconds: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        // Set non-blocking
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        // Use poll() instead of select() — avoids fd_set portability issues
        var pfd = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, Int32(timeoutSeconds * 1000))
        guard pollResult > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        var error: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &errorLen)
        return error == 0
    }

    // MARK: - Remote Configuration Handoff

    private func buildRemoteConfiguration(localPort: Int) -> WorkspaceRemoteConfiguration {
        let startupCommand: String?
        if let script = configuration.gitSetupScript, !script.isEmpty {
            startupCommand = "(\(script)) && cd /workspace/repo 2>/dev/null; exec $SHELL -l"
        } else {
            startupCommand = nil
        }

        return WorkspaceRemoteConfiguration(
            destination: "\(configuration.sshUser)@127.0.0.1",
            port: localPort,
            identityFile: Self.defaultSSHKeyPath(),
            sshOptions: [
                "StrictHostKeyChecking=no",
                "UserKnownHostsFile=/dev/null",
                "LogLevel=ERROR",
                "ForwardAgent=yes",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: startupCommand
        )
    }

    // MARK: - Helpers

    private static func resolveFlyCLI() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/fly",
            "/usr/local/bin/fly",
            "/opt/homebrew/bin/flyctl",
            "/usr/local/bin/flyctl",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try PATH resolution
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["fly"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try whichProcess.run()
        whichProcess.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw FlyControllerError.flyCLINotFound
        }
        return path
    }

    private static func findAvailablePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { throw FlyControllerError.portAllocationFailed }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS picks
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw FlyControllerError.portAllocationFailed }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &addrLen)
            }
        }
        guard nameResult == 0 else { throw FlyControllerError.portAllocationFailed }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    /// Returns the path to the user's default SSH public key, if it exists.
    static func defaultSSHKeyPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.ssh/id_ed25519",
            "\(home)/.ssh/id_rsa",
            "\(home)/.ssh/id_ecdsa",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Reads the user's default SSH public key content.
    static func readDefaultSSHPublicKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.ssh/id_ed25519.pub",
            "\(home)/.ssh/id_rsa.pub",
            "\(home)/.ssh/id_ecdsa.pub",
        ]
        for path in candidates {
            if let content = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            {
                return content
            }
        }
        return nil
    }
}

// MARK: - Errors

enum FlyControllerError: LocalizedError {
    case flyCLINotFound
    case proxyLaunchFailed
    case sshNotReachable
    case portAllocationFailed
    case noSSHPublicKey

    var errorDescription: String? {
        switch self {
        case .flyCLINotFound:
            return "fly CLI not found. Install with: brew install flyctl"
        case .proxyLaunchFailed:
            return "Failed to launch fly proxy tunnel"
        case .sshNotReachable:
            return "SSH on fly.io machine did not become reachable"
        case .portAllocationFailed:
            return "Failed to allocate a local port for SSH tunnel"
        case .noSSHPublicKey:
            return "No SSH public key found in ~/.ssh/. Generate one with: ssh-keygen -t ed25519"
        }
    }
}
