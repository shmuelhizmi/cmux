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
                workspace.cloudMachineState = .starting
                try await api.startSandbox(id: existingID)
                sandboxID = existingID
            } else {
                workspace.cloudMachineState = .creating
                let sandbox = try await createSandbox()
                sandboxID = sandbox.id
                configuration.resolvedSandboxID = sandboxID
                workspace.cloudConfiguration?.resolvedSandboxID = sandboxID
            }

            try Task.checkCancellation()

            // Step 2: Poll until the sandbox is running
            workspace.cloudMachineState = .starting
            try await waitForRunning(sandboxID: sandboxID)

            try Task.checkCancellation()

            // Step 3: Create SSH access
            workspace.cloudMachineState = .waitingForSSH
            let sshAccess = try await api.createSSHAccess(sandboxId: sandboxID, expiresInMinutes: 60)

            try Task.checkCancellation()

            // Step 4: Hand off to existing remote session infrastructure
            let remoteConfig = buildRemoteConfiguration(sshToken: sshAccess.token)
            workspace.configureRemoteConnection(remoteConfig, autoConnect: true)
            workspace.cloudMachineState = .ready

        } catch is CancellationError {
            // Normal cancellation, don't report error
        } catch {
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
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=no",
                "UserKnownHostsFile=/dev/null",
                "LogLevel=ERROR",
            ],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: startupCommand
        )
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
