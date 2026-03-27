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
        // Track which step we're on so error messages include context
        var currentStep = ""
        do {
            try Task.checkCancellation()

            // Step 1: Create or start the sandbox
            let sandboxID: String
            if let existingID = configuration.resolvedSandboxID {
                currentStep = "Starting sandbox"
#if DEBUG
                dlog("daytona.provision startExisting id=\(existingID)")
#endif
                workspace.cloudMachineState = .starting
                workspace.cloudMachineStepOutput = "Resuming sandbox \(existingID.prefix(8))..."
                try await api.startSandbox(id: existingID)
                sandboxID = existingID
            } else {
                currentStep = "Creating sandbox"
#if DEBUG
                dlog("daytona.provision createNew snapshot=\(configuration.sandboxSpec.snapshot ?? "nil")")
#endif
                workspace.cloudMachineState = .creating
                let dc = configuration.devContainer
                if let img = dc?.image {
                    workspace.cloudMachineStepOutput = "Image: \(img)"
                } else if let snapshot = configuration.sandboxSpec.snapshot {
                    workspace.cloudMachineStepOutput = "Snapshot: \(snapshot)"
                }
                let sandbox = try await createSandbox()
                sandboxID = sandbox.id
                configuration.resolvedSandboxID = sandboxID
                workspace.cloudConfiguration?.resolvedSandboxID = sandboxID
                workspace.cloudMachineStepOutput = "Created \(sandboxID.prefix(8))"
#if DEBUG
                dlog("daytona.provision created id=\(sandboxID)")
#endif
            }

            try Task.checkCancellation()

            // Step 2: Poll until the sandbox is running
            currentStep = "Starting sandbox"
            workspace.cloudMachineState = .starting
            workspace.cloudMachineStepOutput = "Waiting for sandbox to be ready..."
            try await waitForRunning(sandboxID: sandboxID, workspace: workspace)
            workspace.cloudMachineStepOutput = "Sandbox running"
#if DEBUG
            dlog("daytona.provision sandbox running id=\(sandboxID)")
#endif

            try Task.checkCancellation()

            // Step 3: Create SSH access
            currentStep = "Obtaining SSH access"
            workspace.cloudMachineState = .waitingForSSH
            workspace.cloudMachineStepOutput = "Requesting SSH token..."
            let sshAccess = try await api.createSSHAccess(sandboxId: sandboxID, expiresInMinutes: 60)
            workspace.cloudMachineStepOutput = "SSH token obtained"
#if DEBUG
            dlog("daytona.provision sshToken obtained, length=\(sshAccess.token.count)")
#endif

            try Task.checkCancellation()

            // Step 4: Connect to sandbox via SSH
            currentStep = "Connecting to sandbox"
            workspace.cloudMachineState = .connecting
            workspace.cloudMachineStepOutput = "ssh \(sshAccess.token.prefix(8))...@ssh.app.daytona.io"
            let remoteConfig = buildRemoteConfiguration(sshToken: sshAccess.token)
#if DEBUG
            dlog("daytona.provision handoff dest=\(remoteConfig.destination) identity=\(remoteConfig.identityFile ?? "nil") options=\(remoteConfig.sshOptions) startupCmd=\(remoteConfig.terminalStartupCommand ?? "nil") uploadViaSSHPipe=\(remoteConfig.uploadViaSSHPipe)")
            if let scriptPath = remoteConfig.terminalStartupCommand,
               let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8) {
                dlog("daytona.provision startupScript.content=\(scriptContent.replacingOccurrences(of: "\n", with: "\\n"))")
            }
#endif
            workspace.configureRemoteConnection(remoteConfig, autoConnect: true)
            workspace.cloudMachineStepOutput = "Bootstrapping remote daemon..."
#if DEBUG
            dlog("daytona.provision step4.waitBegin remoteState=\(workspace.remoteConnectionState.rawValue)")
#endif

            // Wait for remote connection to be established
            try await waitForRemoteConnection(workspace: workspace)
#if DEBUG
            dlog("daytona.provision step4.waitDone remoteState=\(workspace.remoteConnectionState.rawValue)")
#endif
            workspace.cloudMachineStepOutput = "Connected"

            try Task.checkCancellation()

            // Step 5: Clone repository via SSH (not in the terminal)
#if DEBUG
            dlog("daytona.provision step5.check hasScript=\(configuration.gitSetupScript != nil) scriptLen=\(configuration.gitSetupScript?.count ?? 0)")
#endif
            if let script = configuration.gitSetupScript, !script.isEmpty {
                currentStep = "Cloning repository"
                workspace.cloudMachineState = .cloningRepository
                workspace.cloudMachineStepOutput = "Running git setup..."
#if DEBUG
                dlog("daytona.provision step5.cloneBegin script=\(script.replacingOccurrences(of: "\n", with: "\\n").prefix(500))")
#endif
                try await runSSHCommand(
                    script,
                    sshToken: sshAccess.token,
                    workspace: workspace
                )
                // Also run postCreateCommand if present
                if let postCreate = configuration.devContainer?.postCreateCommand?.shellString {
                    workspace.cloudMachineStepOutput = "Running postCreateCommand..."
                    try await runSSHCommand(
                        "cd /home/daytona/repo && " + postCreate,
                        sshToken: sshAccess.token,
                        workspace: workspace
                    )
                }
                workspace.cloudMachineStepOutput = "Repository ready"
            }

            workspace.cloudMachineStepOutput = nil
#if DEBUG
            dlog("daytona.provision settingReady wsId=\(workspace.id) currentState=\(workspace.cloudMachineState.rawValue) hasCloudConfig=\(workspace.cloudConfiguration != nil)")
#endif
            workspace.cloudMachineState = .ready
#if DEBUG
            dlog("daytona.provision complete state=\(workspace.cloudMachineState.rawValue)")
#endif

        } catch is CancellationError {
#if DEBUG
            dlog("daytona.provision cancelled")
#endif
        } catch {
            let errorDetail: String
            if let apiErr = error as? DaytonaAPIError {
                errorDetail = apiErr.errorDescription ?? String(describing: error)
            } else {
                errorDetail = error.localizedDescription
            }
            let detail = currentStep.isEmpty ? errorDetail : "\(currentStep): \(errorDetail)"
#if DEBUG
            dlog("daytona.provision error: \(detail)")
#endif
            workspace.cloudMachineErrorAtStep = workspace.cloudMachineState
            workspace.cloudMachineState = .error
            workspace.cloudMachineDetail = detail
        }
    }

    // MARK: - Sandbox Creation

    private func createSandbox() async throws -> DaytonaSandbox {
        let spec = configuration.sandboxSpec
        let dc = configuration.devContainer

        var env: [String: String] = [
            "CMUX_CLOUD": "1",
            "SHELL": "/bin/bash",
            "USER": "daytona",
            "TERM": "xterm-256color",
        ]
        if let containerEnv = dc?.containerEnv {
            env.merge(containerEnv) { _, new in new }
        }
        if let remoteEnv = dc?.remoteEnv {
            env.merge(remoteEnv) { _, new in new }
        }

        // Use devcontainer image when available.
        // When the devcontainer has a Dockerfile, the detect() method extracts the FROM base image.
        let useImage = dc?.image != nil
#if DEBUG
        if let dc {
            dlog("daytona.provision devcontainer image=\(dc.image ?? "nil") build.dockerfile=\(dc.build?.dockerfile ?? "nil") useImage=\(useImage)")
        }
#endif

        let effectiveImage = useImage ? dc?.image : nil
        let effectiveSnapshot = useImage ? nil : spec.snapshot
#if DEBUG
        dlog("daytona.provision createRequest image=\(effectiveImage ?? "nil") snapshot=\(effectiveSnapshot ?? "nil") envCount=\(env.count) autoStop=\(configuration.autoStopInterval ?? -1)")
#endif
        let request = DaytonaSandboxCreateRequest(
            cpu: spec.cpu,
            memory: spec.memory,
            disk: spec.disk,
            image: effectiveImage,
            env: env,
            labels: ["cmux": "true"],
            snapshot: effectiveSnapshot,
            language: spec.language,
            region: spec.region,
            autostopTimeoutMinutes: configuration.autoStopInterval
        )
        return try await api.createSandbox(request: request)
    }

    // MARK: - State Polling

    private func waitForRunning(sandboxID: String, workspace: Workspace? = nil, maxAttempts: Int = 60, delaySeconds: UInt64 = 2) async throws {
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            let sandbox = try await api.getSandbox(id: sandboxID)
            let state = sandbox.state ?? "unknown"
#if DEBUG
            if attempt == 1 || attempt % 5 == 0 {
                dlog("daytona.poll attempt=\(attempt) state=\(state) id=\(sandboxID)")
            }
#endif
            workspace?.cloudMachineStepOutput = "State: \(state) (attempt \(attempt)/\(maxAttempts))"
            if state == "running" || state == "started" {
                return
            }
            if state == "error" {
                throw DaytonaControllerError.sandboxNotReachable
            }
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
        throw DaytonaControllerError.sandboxNotReachable
    }

    // MARK: - SSH Command Execution

    /// Runs a shell command on the sandbox via SSH. Streams output lines to `cloudMachineStepOutput`.
    /// Runs the blocking process off the main actor to avoid freezing the UI.
    private func runSSHCommand(
        _ command: String,
        sshToken: String,
        workspace: Workspace
    ) async throws {
        try Task.checkCancellation()
        let destination = "\(sshToken)@ssh.app.daytona.io"
        let identityFile = Self.defaultSSHKeyPath()

        var args = [String]()
        if let identityFile {
            args += ["-i", identityFile]
        }
        args += [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "BatchMode=no",
            "-o", "PasswordAuthentication=no",
            "-o", "PreferredAuthentications=publickey,keyboard-interactive,none",
            "-o", "ConnectTimeout=10",
            destination,
            command,
        ]

#if DEBUG
        dlog("daytona.ssh.exec command=\(command.prefix(200))")
#endif

        // Run blocking process work on a background thread
        let result: SSHCommandResult = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            let outputHandle = stdoutPipe.fileHandleForReading
            let errorHandle = stderrPipe.fileHandleForReading

            // Collect all output
            var stdoutLines: [String] = []
            var stderrBuf = Data()

            // Read stdout and stderr in parallel threads
            let stdoutThread = Thread {
                while true {
                    let data = outputHandle.availableData
                    if data.isEmpty { break }
                    if let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        stdoutLines.append(contentsOf: lines)
                        // Update UI on main actor with the last line
                        let lastLine = String(lines.last!.prefix(80))
                        DispatchQueue.main.async { [weak workspace] in
                            workspace?.cloudMachineStepOutput = lastLine
                        }
                    }
                }
            }
            let stderrThread = Thread {
                while true {
                    let data = errorHandle.availableData
                    if data.isEmpty { break }
                    stderrBuf.append(data)
                }
            }
            stdoutThread.start()
            stderrThread.start()

            process.waitUntilExit()
            // Give pipe readers a moment to finish
            Thread.sleep(forTimeInterval: 0.1)

            let exitCode = process.terminationStatus
            let stderrStr = String(data: stderrBuf, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return SSHCommandResult(
                exitCode: exitCode,
                stdoutLines: stdoutLines,
                stderr: stderrStr
            )
        }.value

#if DEBUG
        dlog("daytona.ssh.exec.done exitCode=\(result.exitCode) stdoutLines=\(result.stdoutLines.count) stderr=\(result.stderr.prefix(200)) lastStdout=\(result.stdoutLines.last?.prefix(100) ?? "nil")")
#endif
        if result.exitCode != 0 {
            // Include both stderr and last stdout lines for context
            let output = result.stderr.isEmpty
                ? result.stdoutLines.suffix(5).joined(separator: "\n")
                : result.stderr
            throw DaytonaControllerError.setupCommandFailed(exitCode: result.exitCode, output: output)
        }
    }

    private struct SSHCommandResult: Sendable {
        let exitCode: Int32
        let stdoutLines: [String]
        let stderr: String
    }

    // MARK: - Remote Connection Wait

    /// Polls the workspace's remote connection state until connected or error, with timeout.
    private func waitForRemoteConnection(workspace: Workspace, timeoutSeconds: Int = 60) async throws {
#if DEBUG
        dlog("daytona.waitRemote.begin initialState=\(workspace.remoteConnectionState.rawValue) timeout=\(timeoutSeconds)")
#endif
        for attempt in 1...(timeoutSeconds * 2) {
            try Task.checkCancellation()
            let state = workspace.remoteConnectionState
#if DEBUG
            if attempt <= 5 || attempt % 10 == 0 {
                dlog("daytona.waitRemote attempt=\(attempt) state=\(state.rawValue)")
            }
#endif
            switch state {
            case .connected:
#if DEBUG
                dlog("daytona.waitRemote.connected attempt=\(attempt)")
#endif
                return
            case .error:
#if DEBUG
                dlog("daytona.waitRemote.error attempt=\(attempt)")
#endif
                throw DaytonaControllerError.remoteConnectionFailed
            case .connecting, .disconnected:
                if attempt % 10 == 0 {
                    workspace.cloudMachineStepOutput = "Bootstrapping remote daemon... (\(attempt / 2)s)"
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
#if DEBUG
        dlog("daytona.waitRemote.timeout")
#endif
        throw DaytonaControllerError.remoteConnectionFailed
    }

    // MARK: - Remote Configuration Handoff

    private func buildRemoteConfiguration(sshToken: String) -> WorkspaceRemoteConfiguration {
        let destination = "\(sshToken)@ssh.app.daytona.io"
        let sshOptions = [
            "StrictHostKeyChecking=no",
            "UserKnownHostsFile=/dev/null",
            "LogLevel=ERROR",
            // Daytona SSH proxy authenticates via the token in the username.
            // Override BatchMode=yes (set by the remote session controller) so that
            // keyboard-interactive auth works — Daytona's proxy requires it.
            "BatchMode=no",
            "PasswordAuthentication=no",
            "PreferredAuthentications=publickey,keyboard-interactive,none",
        ]
        let identityFile = Self.defaultSSHKeyPath()

        // Build the SSH command that terminals will use to connect to the sandbox.
        // terminalStartupCommand is used for ALL terminals in this workspace (initial + new tabs/splits).
        // It must be an SSH command — not a local script.
        // IMPORTANT: -tt must come BEFORE the destination. SSH treats everything after
        // the destination as the remote command, so -tt after destination would be sent
        // to the remote shell as a literal command (causing immediate exit).

        // Daytona's SSH proxy does NOT allocate a PTY even with ssh -tt.
        // Use `script -qc "..." /dev/null` on the remote to force PTY allocation
        // so that bash gets an interactive terminal with prompt, colors, etc.
        // Git clone and setup run during provisioning (via runSSHCommand), so the
        // terminal startup command just opens a shell in the repo directory.
        let remoteScript = "cd /home/daytona/repo 2>/dev/null; exec script -qc \"/bin/bash --login\" /dev/null"
        let sshCmd = Self.buildSSHCommandUnquoted(destination: destination, identityFile: identityFile, sshOptions: sshOptions, extraFlags: ["-tt"])
        let escapedRemoteScript = remoteScript.replacingOccurrences(of: "'", with: "'\\''")
        let startupCommand = Self.writeStartupScript(
            "exec " + sshCmd + " '\(escapedRemoteScript)'"
        )

        return WorkspaceRemoteConfiguration(
            destination: destination,
            port: nil,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: startupCommand,
            uploadViaSSHPipe: true
        )
    }

    /// Build an SSH command for use inside a startup script where the ssh line is the
    /// top-level command (not nested inside another quoting context).
    /// Options that contain no special shell characters are left unquoted;
    /// the identity file path is single-quoted since it may contain spaces.
    /// `extraFlags` (e.g. ["-tt"]) are placed before -i/-o options, ensuring they
    /// appear before the destination (SSH treats post-destination args as the remote command).
    private static func buildSSHCommandUnquoted(
        destination: String,
        identityFile: String?,
        sshOptions: [String],
        extraFlags: [String] = []
    ) -> String {
        var args = ["ssh"]
        args += extraFlags
        if let identityFile {
            args += ["-i", shellQuote(identityFile)]
        }
        for option in sshOptions {
            args += ["-o", option]
        }
        args.append(shellQuote(destination))
        return args.joined(separator: " ")
    }

    /// Write a startup script to a temp file and return the quoted path.
    private static func writeStartupScript(_ body: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-daytona-startup-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(body)\n"
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            return body
        }
        return scriptURL.path
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    case remoteConnectionFailed
    case setupCommandFailed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .sandboxNotReachable:
            return "Daytona sandbox did not become reachable"
        case .sshAccessFailed:
            return "Failed to create SSH access for Daytona sandbox"
        case .remoteConnectionFailed:
            return "Failed to establish remote connection to sandbox"
        case .setupCommandFailed(let exitCode, let output):
            if output.isEmpty {
                return "Setup command failed (exit code \(exitCode))"
            }
            return "Setup failed (exit \(exitCode)): \(output)"
        }
    }
}
