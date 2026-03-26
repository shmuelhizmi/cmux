import Bonsplit
import Foundation

/// Manages the lifecycle of a single Daytona sandbox for a cloud workspace.
/// Provisions the sandbox, obtains an SSH access token, then hands off to the
/// existing `WorkspaceRemoteSessionController` via `workspace.configureRemoteConnection()`.
@MainActor
final class DaytonaSandboxController {
    private let api: DaytonaAPI
    private weak var workspace: Workspace?
    private var configuration: DaytonaCloudConfiguration

    private var isStopping = false
    private var provisioningTask: Task<Void, Never>?

    init(
        workspace: Workspace,
        configuration: DaytonaCloudConfiguration,
        apiToken: String
    ) {
        self.workspace = workspace
        self.configuration = configuration
        self.api = DaytonaAPI(token: apiToken)
    }

    deinit {
        provisioningTask?.cancel()
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

        guard let workspace, let sandboxID = configuration.resolvedSandboxID else {
            workspace?.cloudMachineState = .stopped
            return
        }
        workspace.cloudMachineState = .stopping
        let api = self.api
        Task.detached {
            try? await api.stopSandbox(id: sandboxID)
            await MainActor.run { [weak workspace] in
                workspace?.cloudMachineState = .stopped
            }
        }
    }

    func destroy() {
        isStopping = true
        provisioningTask?.cancel()
        provisioningTask = nil

        guard let workspace, let sandboxID = configuration.resolvedSandboxID else {
            workspace?.cloudMachineState = .destroyed
            workspace?.cloudConfiguration = nil
            return
        }
        workspace.cloudMachineState = .destroying
        let api = self.api
        Task.detached {
            try? await api.deleteSandbox(id: sandboxID)
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

            // Step 1: Create or start the sandbox
            let sandboxID: String
            if let existingID = configuration.resolvedSandboxID {
#if DEBUG
                dlog("daytona.provision startExisting id=\(existingID)")
#endif
                workspace.cloudMachineState = .starting
                try await api.startSandbox(id: existingID)
                sandboxID = existingID
            } else {
#if DEBUG
                dlog("daytona.provision createNew snapshot=\(configuration.sandboxSpec.snapshot ?? "nil")")
#endif
                workspace.cloudMachineState = .creating
                let sandbox = try await createSandbox()
                sandboxID = sandbox.id
                configuration.resolvedSandboxID = sandboxID
                workspace.cloudConfiguration?.resolvedSandboxID = sandboxID
#if DEBUG
                dlog("daytona.provision created id=\(sandboxID)")
#endif
            }

            try Task.checkCancellation()

            // Step 2: Poll until the sandbox is running
            workspace.cloudMachineState = .starting
            try await waitForRunning(sandboxID: sandboxID)
#if DEBUG
            dlog("daytona.provision sandbox running id=\(sandboxID)")
#endif

            try Task.checkCancellation()

            // Step 3: Create SSH access
            workspace.cloudMachineState = .waitingForSSH
            let sshAccess = try await api.createSSHAccess(sandboxId: sandboxID, expiresInMinutes: 60)
#if DEBUG
            dlog("daytona.provision sshToken obtained, length=\(sshAccess.token.count)")
#endif

            try Task.checkCancellation()

            // Step 4: Hand off to existing remote session infrastructure
            let remoteConfig = buildRemoteConfiguration(sshToken: sshAccess.token)
#if DEBUG
            dlog("daytona.provision handoff dest=\(remoteConfig.destination) identity=\(remoteConfig.identityFile ?? "nil") options=\(remoteConfig.sshOptions)")
#endif
            workspace.configureRemoteConnection(remoteConfig, autoConnect: true)
            workspace.cloudMachineState = .ready
#if DEBUG
            dlog("daytona.provision complete")
#endif

        } catch is CancellationError {
#if DEBUG
            dlog("daytona.provision cancelled")
#endif
        } catch {
#if DEBUG
            dlog("daytona.provision error: \(error.localizedDescription)")
#endif
            workspace.cloudMachineState = .error
            workspace.cloudMachineDetail = error.localizedDescription
        }
    }

    // MARK: - Sandbox Creation

    private func createSandbox() async throws -> DaytonaSandbox {
        let spec = configuration.sandboxSpec
        let request = DaytonaSandboxCreateRequest(
            cpu: spec.cpu,
            memory: spec.memory,
            disk: spec.disk,
            env: ["CMUX_CLOUD": "1"],
            labels: ["cmux": "true"],
            snapshot: spec.snapshot,
            language: spec.language,
            region: spec.region,
            autostopTimeoutMinutes: configuration.autoStopInterval
        )
        return try await api.createSandbox(request: request)
    }

    // MARK: - State Polling

    private func waitForRunning(sandboxID: String, maxAttempts: Int = 60, delaySeconds: UInt64 = 2) async throws {
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            let sandbox = try await api.getSandbox(id: sandboxID)
#if DEBUG
            if attempt == 1 || attempt % 5 == 0 {
                dlog("daytona.poll attempt=\(attempt) state=\(sandbox.state ?? "nil") id=\(sandboxID)")
            }
#endif
            if sandbox.state == "running" || sandbox.state == "started" {
                return
            }
            if sandbox.state == "error" {
                throw DaytonaControllerError.sandboxNotReachable
            }
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
        throw DaytonaControllerError.sandboxNotReachable
    }

    // MARK: - Remote Configuration Handoff

    private func buildRemoteConfiguration(sshToken: String) -> WorkspaceRemoteConfiguration {
        let startupCommand: String?
        if let script = configuration.gitSetupScript, !script.isEmpty {
            startupCommand = "(\(script)) && cd /home/daytona/repo 2>/dev/null; exec $SHELL -l"
        } else {
            startupCommand = nil
        }

        return WorkspaceRemoteConfiguration(
            destination: "\(sshToken)@ssh.app.daytona.io",
            port: nil,
            identityFile: Self.defaultSSHKeyPath(),
            sshOptions: [
                "StrictHostKeyChecking=no",
                "UserKnownHostsFile=/dev/null",
                "LogLevel=ERROR",
                // Daytona SSH proxy authenticates via the token in the username.
                // Override BatchMode=yes (set by the remote session controller) so that
                // keyboard-interactive auth works — Daytona's proxy requires it.
                "BatchMode=no",
                "PasswordAuthentication=no",
                "PreferredAuthentications=publickey,keyboard-interactive,none",
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

    /// Returns the path to the user's default SSH private key, if it exists.
    private static func defaultSSHKeyPath() -> String? {
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
}

// MARK: - Errors

enum DaytonaControllerError: LocalizedError {
    case sandboxNotReachable
    case sshAccessFailed

    var errorDescription: String? {
        switch self {
        case .sandboxNotReachable:
            return "Daytona sandbox did not become reachable"
        case .sshAccessFailed:
            return "Failed to create SSH access for Daytona sandbox"
        }
    }
}
