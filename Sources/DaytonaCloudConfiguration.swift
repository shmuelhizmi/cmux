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

    init(
        sandboxSpec: DaytonaCloudSandboxSpec = .default,
        gitSetupScript: String? = nil,
        workspaceLabel: String? = nil,
        resolvedSandboxID: String? = nil,
        autoStopInterval: Int? = nil
    ) {
        self.sandboxSpec = sandboxSpec
        self.gitSetupScript = gitSetupScript
        self.workspaceLabel = workspaceLabel
        self.resolvedSandboxID = resolvedSandboxID
        self.autoStopInterval = autoStopInterval
    }
}

// MARK: - Machine State

enum DaytonaCloudMachineState: String, Codable, Sendable {
    case creating
    case starting
    case waitingForSSH
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
    static func buildGitSetupScript(
        mode: String,
        repoURL: String,
        branchName: String? = nil,
        baseBranch: String? = nil,
        newBranchName: String? = nil,
        prNumber: Int? = nil,
        repoSlug: String? = nil
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

        switch mode {
        case "create_branch":
            let base = baseBranch ?? "main"
            let newBranch = newBranchName ?? "new-branch"
            return """
            set -e
            \(installGit)
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
            echo "Cloning \(shellEscape(repoURL)) (branch: \(shellEscape(branch)))..."
            git clone --branch \(shellEscape(branch)) \(shellEscape(repoURL)) /home/daytona/repo
            cd /home/daytona/repo
            echo "Ready on branch \(shellEscape(branch))"
            """

        case "import_pr":
            let num = prNumber ?? 0
            let slug = repoSlug ?? ""
            return """
            set -e
            \(installGit)
            echo "Cloning \(shellEscape(repoURL))..."
            git clone \(shellEscape(repoURL)) /home/daytona/repo
            cd /home/daytona/repo
            if command -v gh >/dev/null 2>&1; then
                gh pr checkout \(num)\(slug.isEmpty ? "" : " --repo \(shellEscape(slug))")
            else
                echo "Installing gh CLI..."
                (type -p wget >/dev/null || (apt-get update -qq && apt-get install -y -qq wget >/dev/null 2>&1)) && \
                wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null && \
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list >/dev/null && \
                apt-get update -qq && apt-get install -y -qq gh >/dev/null 2>&1
                gh pr checkout \(num)\(slug.isEmpty ? "" : " --repo \(shellEscape(slug))")
            fi
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
