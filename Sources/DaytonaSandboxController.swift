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
            dlog("daytona.provision handoff dest=\(remoteConfig.destination) identity=\(remoteConfig.identityFile ?? "nil") options=\(remoteConfig.sshOptions) startupCmd=\(remoteConfig.terminalStartupCommand ?? "nil") uploadViaSSHPipe=\(remoteConfig.uploadViaSSHPipe)")
            // Log the actual script content so we can verify the SSH command is correct
            if let scriptPath = remoteConfig.terminalStartupCommand,
               let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8) {
                dlog("daytona.provision startupScript.content=\(scriptContent.replacingOccurrences(of: "\n", with: "\\n"))")
            }
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
            env: [
                "CMUX_CLOUD": "1",
                "SHELL": "/bin/bash",
                "USER": "daytona",
                "TERM": "xterm-256color",
            ],
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
        let startupCommand: String
        if let script = configuration.gitSetupScript, !script.isEmpty {
            // SSH into sandbox, run the git setup, then start an interactive login shell.
            // For the initial terminal, the setup runs (clone etc.).
            // For subsequent terminals, the clone is already done so the cd succeeds and the shell starts.
            let remoteScript = "cd /home/daytona/repo 2>/dev/null || { " + script + " && cd /home/daytona/repo 2>/dev/null; }; exec script -qc \"/bin/bash --login\" /dev/null"
            let sshCmd = Self.buildSSHCommandUnquoted(destination: destination, identityFile: identityFile, sshOptions: sshOptions, extraFlags: ["-tt"])
            // The remote command is single-quoted so no local shell expansion occurs.
            // Single quotes within the remote script are escaped as '\'' (end quote,
            // escaped literal quote, restart quote).
            let escapedRemoteScript = remoteScript.replacingOccurrences(of: "'", with: "'\\''")
            startupCommand = Self.writeStartupScript(
                "exec " + sshCmd + " '\(escapedRemoteScript)'"
            )
        } else {
            let remoteScript = "exec script -qc \"/bin/bash --login\" /dev/null"
            let sshCmd = Self.buildSSHCommandUnquoted(destination: destination, identityFile: identityFile, sshOptions: sshOptions, extraFlags: ["-tt"])
            let escapedRemoteScript = remoteScript.replacingOccurrences(of: "'", with: "'\\''")
            startupCommand = Self.writeStartupScript(
                "exec " + sshCmd + " '\(escapedRemoteScript)'"
            )
        }

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

    var errorDescription: String? {
        switch self {
        case .sandboxNotReachable:
            return "Daytona sandbox did not become reachable"
        case .sshAccessFailed:
            return "Failed to create SSH access for Daytona sandbox"
        }
    }
}
