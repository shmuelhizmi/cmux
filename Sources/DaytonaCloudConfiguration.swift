import Foundation

// MARK: - Sandbox Spec

struct DaytonaCloudSandboxSpec: Codable, Equatable, Sendable {
    let cpu: Int
    let memory: Int
    let disk: Int
    let snapshot: String?
    let region: String?
    let language: String?

    static let `default` = DaytonaCloudSandboxSpec(
        cpu: 1,
        memory: 1,
        disk: 10,
        snapshot: "daytona-small",
        region: nil,
        language: nil
    )

    /// Build a spec from the user's saved settings, falling back to defaults.
    static func fromSettings(defaults: UserDefaults = .standard) -> DaytonaCloudSandboxSpec {
        let cpu = defaults.object(forKey: CloudMachineSettings.cpuKey) as? Int ?? CloudMachineSettings.defaultCPU
        let memory = defaults.object(forKey: CloudMachineSettings.memoryKey) as? Int ?? CloudMachineSettings.defaultMemory
        let disk = defaults.object(forKey: CloudMachineSettings.diskKey) as? Int ?? CloudMachineSettings.defaultDisk
        let snapshot = defaults.string(forKey: CloudMachineSettings.snapshotKey)
        return DaytonaCloudSandboxSpec(
            cpu: cpu,
            memory: memory,
            disk: disk,
            snapshot: snapshot ?? Self.default.snapshot,
            region: nil,
            language: nil
        )
    }
}

// MARK: - Machine Settings

enum CloudMachineSettings {
    static let cpuKey = "cloud.machine.cpu"
    static let memoryKey = "cloud.machine.memory"
    static let diskKey = "cloud.machine.disk"
    static let snapshotKey = "cloud.machine.snapshot"

    static let defaultCPU = 2
    static let defaultMemory = 4
    static let defaultDisk = 20

    static let cpuSteps = [1, 2, 4, 8]
    static let memorySteps = [1, 2, 4, 8, 16]
    static let diskSteps = [10, 20, 50, 100]
}

// MARK: - Cloud Configuration

struct DaytonaCloudConfiguration: Codable, Equatable, Sendable {
    let sandboxSpec: DaytonaCloudSandboxSpec

    /// Shell script to run on the sandbox after SSH is ready (e.g. git clone + checkout).
    /// Passed as `terminalStartupCommand` so the user sees output in the terminal.
    var gitSetupScript: String?

    /// Human-readable label for the workspace (e.g. branch name or PR title).
    var workspaceLabel: String?

    /// Populated after sandbox creation
    var resolvedSandboxID: String?

    /// Auto-stop interval in minutes (0 = never).
    var autoStopInterval: Int?

    /// Parsed `.devcontainer/devcontainer.json` from the local repo, if present.
    var devContainer: DevContainerConfig?

    init(
        sandboxSpec: DaytonaCloudSandboxSpec = .default,
        gitSetupScript: String? = nil,
        workspaceLabel: String? = nil,
        resolvedSandboxID: String? = nil,
        autoStopInterval: Int? = nil,
        devContainer: DevContainerConfig? = nil
    ) {
        self.sandboxSpec = sandboxSpec
        self.gitSetupScript = gitSetupScript
        self.workspaceLabel = workspaceLabel
        self.resolvedSandboxID = resolvedSandboxID
        self.autoStopInterval = autoStopInterval
        self.devContainer = devContainer
    }
}

// MARK: - Machine State

enum DaytonaCloudMachineState: String, Codable, Sendable {
    case creating
    case starting
    case waitingForSSH
    case connecting
    case settingUpDevContainer
    case cloningRepository
    case ready
    case stopping
    case stopped
    case destroying
    case destroyed
    case error
}

// MARK: - Git Setup Scripts

extension DaytonaCloudConfiguration {
    /// Builds a shell script that clones a repo and checks out the right branch/PR on the sandbox.
    /// When `githubToken` is provided, git credential storage is configured so clone, push, pull all work.
    static func buildGitSetupScript(
        mode: String,
        repoURL: String,
        branchName: String? = nil,
        baseBranch: String? = nil,
        newBranchName: String? = nil,
        prNumber: Int? = nil,
        repoSlug: String? = nil,
        githubToken: String? = nil
    ) -> String {
        let installGit = """
        if ! command -v git >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache git >/dev/null 2>&1
            fi
        fi
        """

        // Set up git credential storage so clone/push/pull/fetch all work with private repos.
        let setupCredentials: String
        if let token = githubToken, !token.isEmpty {
            setupCredentials = """
            git config --global credential.helper store
            printf \(shellEscape("https://x-access-token:\(token)@github.com\\n")) > ~/.git-credentials
            chmod 600 ~/.git-credentials
            """
        } else {
            setupCredentials = ""
        }

        switch mode {
        case "create_branch":
            let base = baseBranch ?? "main"
            let newBranch = newBranchName ?? "new-branch"
            return """
            set -e
            \(installGit)
            \(setupCredentials)
            echo "Cloning \(shellEscape(repoURL))..."
            git clone --branch \(shellEscape(base)) \(shellEscape(repoURL)) /home/daytona/repo
            cd /home/daytona/repo
            git checkout -b \(shellEscape(newBranch))
            echo "Created branch \(shellEscape(newBranch)) from \(shellEscape(base))"
            """

        case "import_branch":
            let branch = branchName ?? "main"
            return """
            set -e
            \(installGit)
            \(setupCredentials)
            echo "Cloning \(shellEscape(repoURL)) (branch: \(shellEscape(branch)))..."
            git clone --branch \(shellEscape(branch)) \(shellEscape(repoURL)) /home/daytona/repo
            cd /home/daytona/repo
            echo "Ready on branch \(shellEscape(branch))"
            """

        case "import_pr":
            let num = prNumber ?? 0
            return """
            set -e
            \(installGit)
            \(setupCredentials)
            echo "Cloning \(shellEscape(repoURL))..."
            git clone \(shellEscape(repoURL)) /home/daytona/repo
            cd /home/daytona/repo
            echo "Checking out PR #\(num)..."
            git fetch origin pull/\(num)/head:pr-\(num)
            git checkout pr-\(num)
            echo "Ready on PR #\(num)"
            """

        default:
            return ""
        }
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
