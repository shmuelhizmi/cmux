import SwiftUI

// MARK: - Mode

enum CloudWorkspaceCreationMode: Int, CaseIterable, Identifiable {
    case createBranch
    case importBranch
    case importPR

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .createBranch: return String(localized: "cloud.mode.createBranch", defaultValue: "Create Branch")
        case .importBranch: return String(localized: "cloud.mode.importBranch", defaultValue: "Import Branch")
        case .importPR: return String(localized: "cloud.mode.importPR", defaultValue: "Import PR")
        }
    }
}

// MARK: - Sheet

struct NewCloudWorkspaceSheet: View {
    var currentDirectory: String?
    var onSubmit: (FlyCloudConfiguration, String?) -> Void
    var onLocalWorkspace: () -> Void
    var onDismiss: (() -> Void)?

    @State private var mode: CloudWorkspaceCreationMode = .importBranch
    @State private var repoURL: String = ""
    @State private var branchName: String = ""
    @State private var baseBranch: String = "main"
    @State private var newBranchName: String = ""
    @State private var prIdentifier: String = ""
    @State private var flyAppName: String = ""
    @State private var image: String = "ubuntu:24.04"
    @State private var showAdvanced: Bool = false
    @State private var isResolving: Bool = false
    @State private var resolvedPRBranch: String?
    @State private var resolvedPRRepoSlug: String?
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        guard !flyAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !repoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch mode {
        case .createBranch:
            return !newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .importBranch:
            return !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .importPR:
            return !prIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "cloud.sheet.title", defaultValue: "New Cloud Workspace"))
                .font(.title3.weight(.semibold))

            Picker("", selection: $mode) {
                ForEach(CloudWorkspaceCreationMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            formFields

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            if showAdvanced {
                advancedFields
            } else {
                Button(String(localized: "cloud.sheet.showAdvanced", defaultValue: "Advanced...")) {
                    withAnimation { showAdvanced = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack {
                Button(String(localized: "cloud.sheet.cancel", defaultValue: "Cancel")) {
                    onDismiss?()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "cloud.sheet.create", defaultValue: "Create Workspace")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isResolving)
            }

            Divider()

            Button(String(localized: "cloud.sheet.localWorkspace", defaultValue: "or create a local workspace")) {
                onLocalWorkspace()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(24)
        .accessibilityIdentifier("NewCloudWorkspaceSheet")
        .onAppear {
            autoDetectRepo()
        }
    }

    // MARK: - Form Fields

    @ViewBuilder
    private var formFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField(String(localized: "cloud.field.repoURL", defaultValue: "Repository URL")) {
                TextField("https://github.com/owner/repo", text: $repoURL)
                    .textFieldStyle(.roundedBorder)
            }

            switch mode {
            case .createBranch:
                LabeledField(String(localized: "cloud.field.baseBranch", defaultValue: "Base Branch")) {
                    TextField("main", text: $baseBranch)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledField(String(localized: "cloud.field.newBranchName", defaultValue: "New Branch Name")) {
                    TextField("feature/my-feature", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                }

            case .importBranch:
                LabeledField(String(localized: "cloud.field.branchName", defaultValue: "Branch Name")) {
                    TextField("main", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                }

            case .importPR:
                LabeledField(String(localized: "cloud.field.prIdentifier", defaultValue: "Pull Request")) {
                    HStack {
                        TextField("owner/repo#123 or PR URL", text: $prIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { resolvePR() }
                        if isResolving {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                if let resolvedPRBranch {
                    Text("Branch: \(resolvedPRBranch)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            LabeledField(String(localized: "cloud.field.flyApp", defaultValue: "Fly.io App Name")) {
                TextField("my-dev-app", text: $flyAppName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField(String(localized: "cloud.field.image", defaultValue: "Docker Image")) {
                TextField("ubuntu:24.04", text: $image)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        errorMessage = nil
        let trimmedApp = flyAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepo = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedApp.isEmpty else {
            errorMessage = "Fly.io app name is required"
            return
        }
        guard !trimmedRepo.isEmpty else {
            errorMessage = "Repository URL is required"
            return
        }

        let modeString: String
        let gitBranch: String?
        let gitBaseBranch: String?
        let gitNewBranch: String?
        var prNumber: Int?
        var repoSlug: String?
        var workspaceLabel: String?

        switch mode {
        case .createBranch:
            modeString = "create_branch"
            gitBranch = nil
            gitBaseBranch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            gitNewBranch = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
            workspaceLabel = gitNewBranch

        case .importBranch:
            modeString = "import_branch"
            gitBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            gitBaseBranch = nil
            gitNewBranch = nil
            workspaceLabel = gitBranch

        case .importPR:
            modeString = "import_pr"
            gitBranch = resolvedPRBranch
            gitBaseBranch = nil
            gitNewBranch = nil
            let parsed = Self.parsePRIdentifier(prIdentifier)
            prNumber = parsed.number
            repoSlug = parsed.repoSlug ?? resolvedPRRepoSlug
            workspaceLabel = prNumber.map { "PR #\($0)" }
        }

        let script = FlyCloudConfiguration.buildGitSetupScript(
            mode: modeString,
            repoURL: trimmedRepo,
            branchName: gitBranch,
            baseBranch: gitBaseBranch,
            newBranchName: gitNewBranch,
            prNumber: prNumber,
            repoSlug: repoSlug
        )

        let config = FlyCloudConfiguration(
            appName: trimmedApp,
            machineSpec: FlyCloudMachineSpec(
                cpuKind: "shared",
                cpus: 1,
                memoryMB: 1024,
                image: image.trimmingCharacters(in: .whitespacesAndNewlines),
                region: nil,
                volumeSizeGB: 10
            ),
            volumeName: "workspace-data",
            sshUser: "root",
            gitSetupScript: script,
            workspaceLabel: workspaceLabel
        )

        onSubmit(config, workspaceLabel)
    }

    private func autoDetectRepo() {
        guard let dir = currentDirectory, !dir.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let slugs = GitHubService.repositorySlugs(directory: dir)
            guard let first = slugs.first else { return }
            let url = "https://github.com/\(first).git"
            DispatchQueue.main.async {
                if repoURL.isEmpty {
                    repoURL = url
                }
            }
        }
    }

    private func resolvePR() {
        let identifier = prIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        let parsed = Self.parsePRIdentifier(identifier)
        guard let number = parsed.number, let slug = parsed.repoSlug else { return }

        isResolving = true
        resolvedPRBranch = nil
        resolvedPRRepoSlug = slug

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.ghPRView(number: number, repoSlug: slug)
            DispatchQueue.main.async {
                isResolving = false
                if let branch = result.branch {
                    resolvedPRBranch = branch
                }
                if let repoURLFromPR = result.repoURL, repoURL.isEmpty {
                    repoURL = repoURLFromPR
                }
            }
        }
    }

    // MARK: - PR Parsing

    struct ParsedPR {
        var repoSlug: String?
        var number: Int?
    }

    static func parsePRIdentifier(_ identifier: String) -> ParsedPR {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        // URL form: https://github.com/owner/repo/pull/123
        if trimmed.contains("github.com") {
            let parts = trimmed.components(separatedBy: "/")
            if let pullIndex = parts.firstIndex(of: "pull"),
               pullIndex + 1 < parts.count,
               let number = Int(parts[pullIndex + 1]),
               pullIndex >= 2 {
                let owner = parts[pullIndex - 2]
                let repo = parts[pullIndex - 1]
                return ParsedPR(repoSlug: "\(owner)/\(repo)", number: number)
            }
        }

        // Shorthand: owner/repo#123
        if let hashIndex = trimmed.firstIndex(of: "#") {
            let slug = String(trimmed[trimmed.startIndex..<hashIndex])
            let numStr = String(trimmed[trimmed.index(after: hashIndex)...])
            if !slug.isEmpty, let number = Int(numStr) {
                return ParsedPR(repoSlug: slug, number: number)
            }
        }

        return ParsedPR()
    }

    private static func ghPRView(number: Int, repoSlug: String) -> (branch: String?, repoURL: String?) {
        guard let ghPath = Self.resolvedGHPath() else { return (nil, nil) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = [
            "pr", "view", String(number),
            "--repo", repoSlug,
            "--json", "headRefName,headRepository",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, nil)
        }
        guard process.terminationStatus == 0 else { return (nil, nil) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let branch = json["headRefName"] as? String
        var repoURL: String?
        if let headRepo = json["headRepository"] as? [String: Any],
           let name = headRepo["name"] as? String,
           let owner = headRepo["owner"] as? [String: Any],
           let login = owner["login"] as? String {
            repoURL = "https://github.com/\(login)/\(name).git"
        }
        return (branch, repoURL)
    }
}

// MARK: - Helper: resolvedGHPath

extension NewCloudWorkspaceSheet {
    /// Resolves the path to the `gh` CLI using GitHubService's path resolution.
    static func resolvedGHPath() -> String? {
        GitHubService.resolvedCommandPath(executable: "gh")
    }
}

// MARK: - Labeled Field

private struct LabeledField<Content: View>: View {
    let label: String
    let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
