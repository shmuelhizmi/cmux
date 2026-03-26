import Foundation

// MARK: - Machine Spec

struct FlyCloudMachineSpec: Codable, Equatable, Sendable {
    let cpuKind: String
    let cpus: Int
    let memoryMB: Int
    let image: String
    let region: String?
    let volumeSizeGB: Int?

    static let `default` = FlyCloudMachineSpec(
        cpuKind: "shared",
        cpus: 1,
        memoryMB: 1024,
        image: "ubuntu:24.04",
        region: nil,
        volumeSizeGB: nil
    )
}

// MARK: - Cloud Configuration

struct FlyCloudConfiguration: Codable, Equatable, Sendable {
    let appName: String
    let machineSpec: FlyCloudMachineSpec
    let volumeName: String?
    let sshUser: String

    /// Shell script to run on the machine after SSH is ready (e.g. git clone + checkout).
    /// Passed as `terminalStartupCommand` so the user sees output in the terminal.
    var gitSetupScript: String?

    /// Human-readable label for the workspace (e.g. branch name or PR title).
    var workspaceLabel: String?

    /// Populated after machine creation
    var resolvedMachineID: String?
    /// Populated after volume creation
    var resolvedVolumeID: String?

    init(
        appName: String,
        machineSpec: FlyCloudMachineSpec = .default,
        volumeName: String? = nil,
        sshUser: String = "root",
        gitSetupScript: String? = nil,
        workspaceLabel: String? = nil,
        resolvedMachineID: String? = nil,
        resolvedVolumeID: String? = nil
    ) {
        self.appName = appName
        self.machineSpec = machineSpec
        self.volumeName = volumeName
        self.sshUser = sshUser
        self.gitSetupScript = gitSetupScript
        self.workspaceLabel = workspaceLabel
        self.resolvedMachineID = resolvedMachineID
        self.resolvedVolumeID = resolvedVolumeID
    }
}

// MARK: - Machine State

enum FlyCloudMachineState: String, Codable, Sendable {
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

// MARK: - SSH Bootstrap

extension FlyCloudConfiguration {
    /// Shell script used as the machine's init command.
    /// Installs sshd, injects the user's public key, and starts sshd in the foreground.
    /// Shell script for machine init. The SSH public key is embedded directly.
    static func machineInitScript(sshPublicKey: String, sshUser: String) -> String {
        let home = sshUser == "root" ? "/root" : "/home/\(sshUser)"
        // Base64-encode the pubkey to avoid any shell escaping issues
        let b64Key = Data(sshPublicKey.utf8).base64EncodedString()
        return [
            "apt-get update -qq",
            "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1",
            "mkdir -p \(home)/.ssh /run/sshd",
            "echo \(b64Key) | base64 -d > \(home)/.ssh/authorized_keys",
            "chmod 700 \(home)/.ssh",
            "chmod 600 \(home)/.ssh/authorized_keys",
            "ssh-keygen -A",
            "mkdir -p /etc/ssh/sshd_config.d",
            "printf 'PermitRootLogin yes\\nPubkeyAuthentication yes\\n' > /etc/ssh/sshd_config.d/99-cmux.conf",
            "/usr/sbin/sshd -D -e",
        ].joined(separator: " && ")
    }
}

// MARK: - Git Setup Scripts

extension FlyCloudConfiguration {
    /// Builds a shell script that clones a repo and checks out the right branch/PR on the fly machine.
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
            git clone --branch \(shellEscape(base)) \(shellEscape(repoURL)) /workspace/repo
            cd /workspace/repo
            git checkout -b \(shellEscape(newBranch))
            echo "Created branch \(shellEscape(newBranch)) from \(shellEscape(base))"
            """

        case "import_branch":
            let branch = branchName ?? "main"
            return """
            set -e
            \(installGit)
            echo "Cloning \(shellEscape(repoURL)) (branch: \(shellEscape(branch)))..."
            git clone --branch \(shellEscape(branch)) \(shellEscape(repoURL)) /workspace/repo
            cd /workspace/repo
            echo "Ready on branch \(shellEscape(branch))"
            """

        case "import_pr":
            let num = prNumber ?? 0
            let slug = repoSlug ?? ""
            return """
            set -e
            \(installGit)
            echo "Cloning \(shellEscape(repoURL))..."
            git clone \(shellEscape(repoURL)) /workspace/repo
            cd /workspace/repo
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
