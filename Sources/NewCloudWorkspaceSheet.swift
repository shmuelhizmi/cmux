import SwiftUI

// MARK: - Item Model

enum CloudWorkspaceItem: Identifiable, Equatable {
    case pr(number: Int, title: String, branch: String, repoSlug: String)
    case branch(name: String)
    case createBranch

    var id: String {
        switch self {
        case .pr(let n, _, _, _): return "pr-\(n)"
        case .branch(let name): return "branch-\(name)"
        case .createBranch: return "create-branch"
        }
    }

    var searchText: String {
        switch self {
        case .pr(let n, let title, let branch, _): return "PR #\(n) \(title) \(branch)"
        case .branch(let name): return name
        case .createBranch: return "create new branch"
        }
    }

    var label: String {
        switch self {
        case .pr(let n, let title, _, _): return "#\(n) \(title)"
        case .branch(let name): return name
        case .createBranch: return String(localized: "cloud.item.createBranch", defaultValue: "Create new branch...")
        }
    }

    var detail: String? {
        switch self {
        case .pr(_, _, let branch, _): return branch
        case .branch: return nil
        case .createBranch: return nil
        }
    }

    var iconName: String {
        switch self {
        case .pr: return "arrow.triangle.pull"
        case .branch: return "arrow.triangle.branch"
        case .createBranch: return "plus"
        }
    }

    var iconColor: Color {
        switch self {
        case .pr: return .green
        case .branch: return .secondary
        case .createBranch: return .accentColor
        }
    }
}

// MARK: - Sheet

struct NewCloudWorkspaceSheet: View {
    var currentDirectory: String?
    var onSubmit: (FlyCloudConfiguration, String?) -> Void
    var onLocalWorkspace: () -> Void
    var onDismiss: (() -> Void)?

    @State private var searchText: String = ""
    @State private var items: [CloudWorkspaceItem] = []
    @State private var isLoading: Bool = true
    @State private var selectedIndex: Int = 0
    @State private var detectedRepoSlug: String?
    @State private var detectedRepoURL: String?
    @State private var detectedHead: String?
    @State private var flyAppName: String = ""
    @State private var showCreateBranchInput: Bool = false
    @State private var newBranchName: String = ""
    @State private var newBranchBase: String = "main"
    @State private var errorMessage: String?

    private var filteredItems: [CloudWorkspaceItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.searchText.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField(
                    String(localized: "cloud.search.placeholder", defaultValue: "Search branches and pull requests..."),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { selectCurrentItem() }
                .onChange(of: searchText) { _, _ in selectedIndex = 0 }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if showCreateBranchInput {
                createBranchForm
            } else {
                // Results list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !filteredItems.isEmpty {
                                let prs = filteredItems.filter { if case .pr = $0 { return true }; return false }
                                let branches = filteredItems.filter { if case .branch = $0 { return true }; return false }
                                let actions = filteredItems.filter { if case .createBranch = $0 { return true }; return false }

                                if !prs.isEmpty {
                                    sectionHeader(String(localized: "cloud.section.prs", defaultValue: "Open Pull Requests"))
                                    ForEach(Array(prs.enumerated()), id: \.element.id) { _, item in
                                        itemRow(item)
                                    }
                                }

                                if !branches.isEmpty {
                                    sectionHeader(String(localized: "cloud.section.branches", defaultValue: "Branches"))
                                    ForEach(Array(branches.enumerated()), id: \.element.id) { _, item in
                                        itemRow(item)
                                    }
                                }

                                if !actions.isEmpty {
                                    Divider().padding(.vertical, 4)
                                    ForEach(Array(actions.enumerated()), id: \.element.id) { _, item in
                                        itemRow(item)
                                    }
                                }
                            } else if !isLoading {
                                Text(String(localized: "cloud.search.noResults", defaultValue: "No results found"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { _, newValue in
                        let items = filteredItems
                        guard newValue >= 0, newValue < items.count else { return }
                        proxy.scrollTo(items[newValue].id, anchor: .center)
                    }
                }

                Divider()

                // Footer
                HStack {
                    Button(String(localized: "cloud.sheet.localWorkspace", defaultValue: "Local workspace")) {
                        onLocalWorkspace()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    Spacer()

                    if let slug = detectedRepoSlug {
                        Text(slug)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .accessibilityIdentifier("NewCloudWorkspaceSheet")
        .onAppear {
            loadData()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - Keyboard Event Monitor

    private static let kVKDownArrow: UInt16 = 0x7D
    private static let kVKUpArrow: UInt16 = 0x7E
    private static let kVKEscape: UInt16 = 0x35
    private static let kVKReturn: UInt16 = 0x24
    private static let kVKKeypadEnter: UInt16 = 0x4C

    @State private var keyMonitor: Any?

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            switch event.keyCode {
            case Self.kVKDownArrow:
                let items = filteredItems
                if !items.isEmpty { selectedIndex = min(selectedIndex + 1, items.count - 1) }
                return nil
            case Self.kVKUpArrow:
                let items = filteredItems
                if !items.isEmpty { selectedIndex = max(selectedIndex - 1, 0) }
                return nil
            case Self.kVKReturn, Self.kVKKeypadEnter:
                selectCurrentItem()
                return nil
            case Self.kVKEscape:
                onDismiss?()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Item Row

    private func itemRow(_ item: CloudWorkspaceItem) -> some View {
        let idx = filteredItems.firstIndex(of: item)
        let isSelected = idx == selectedIndex

        return Button {
            if let idx { selectedIndex = idx }
            selectItem(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(item.iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if case .branch(let name) = item, name == detectedHead {
                    Text("HEAD")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .padding(.horizontal, 4)
                    : nil
            )
        }
        .buttonStyle(.plain)
        .id(item.id)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    // MARK: - Create Branch Form

    private var createBranchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledField(String(localized: "cloud.field.baseBranch", defaultValue: "Base Branch")) {
                TextField("main", text: $newBranchBase)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField(String(localized: "cloud.field.newBranchName", defaultValue: "New Branch Name")) {
                TextField("feature/my-feature", text: $newBranchName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCreateBranch() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(String(localized: "cloud.sheet.back", defaultValue: "Back")) {
                    showCreateBranchInput = false
                    errorMessage = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "cloud.sheet.create", defaultValue: "Create Workspace")) {
                    submitCreateBranch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func selectCurrentItem() {
        let items = filteredItems
        guard selectedIndex >= 0, selectedIndex < items.count else { return }
        selectItem(items[selectedIndex])
    }

    private func selectItem(_ item: CloudWorkspaceItem) {
        switch item {
        case .pr(let number, let title, _, let slug):
            submitPR(number: number, title: title, repoSlug: slug)
        case .branch(let name):
            submitBranch(name: name)
        case .createBranch:
            showCreateBranchInput = true
        }
    }

    private func submitBranch(name: String) {
        guard let repoURL = effectiveRepoURL() else { return }
        let script = FlyCloudConfiguration.buildGitSetupScript(
            mode: "import_branch", repoURL: repoURL, branchName: name
        )
        let config = buildConfig(gitSetupScript: script)
        onSubmit(config, name)
    }

    private func submitPR(number: Int, title: String, repoSlug: String) {
        guard let repoURL = effectiveRepoURL() else { return }
        let script = FlyCloudConfiguration.buildGitSetupScript(
            mode: "import_pr", repoURL: repoURL, prNumber: number, repoSlug: repoSlug
        )
        let label = "#\(number) \(title)"
        let config = buildConfig(gitSetupScript: script)
        onSubmit(config, label)
    }

    private func submitCreateBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let repoURL = effectiveRepoURL() else { return }
        let base = newBranchBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = FlyCloudConfiguration.buildGitSetupScript(
            mode: "create_branch", repoURL: repoURL,
            baseBranch: base.isEmpty ? "main" : base,
            newBranchName: name
        )
        let config = buildConfig(gitSetupScript: script)
        onSubmit(config, name)
    }

    private func effectiveRepoURL() -> String? {
        if let url = detectedRepoURL, !url.isEmpty { return url }
        if let slug = detectedRepoSlug, !slug.isEmpty {
            return "https://github.com/\(slug).git"
        }
        errorMessage = "Could not detect repository"
        return nil
    }

    private func buildConfig(gitSetupScript: String) -> FlyCloudConfiguration {
        let app = flyAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = app.isEmpty ? (detectedRepoSlug?.replacingOccurrences(of: "/", with: "-") ?? "dev") : app
        return FlyCloudConfiguration(
            appName: appName,
            machineSpec: .default,
            volumeName: "workspace-data",
            sshUser: "root",
            gitSetupScript: gitSetupScript
        )
    }

    // MARK: - Data Loading

    private func loadData() {
        guard let dir = currentDirectory, !dir.isEmpty else {
            isLoading = false
            items = [.createBranch]
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Detect repo
            let slugs = GitHubService.repositorySlugs(directory: dir)
            let slug = slugs.first
            let repoURL = slug.map { "https://github.com/\($0).git" }

            // Detect HEAD
            let head = Self.detectHead(directory: dir)

            // Fetch branches
            let branches = Self.fetchBranches(directory: dir)

            // Fetch open PRs
            var prs: [CloudWorkspaceItem] = []
            if let slug {
                prs = Self.fetchOpenPRs(repoSlug: slug)
            }

            DispatchQueue.main.async {
                detectedRepoSlug = slug
                detectedRepoURL = repoURL
                detectedHead = head

                var allItems: [CloudWorkspaceItem] = []
                allItems.append(contentsOf: prs)

                // Put HEAD branch first, then others
                var sortedBranches = branches
                if let head, let idx = sortedBranches.firstIndex(of: head) {
                    sortedBranches.remove(at: idx)
                    sortedBranches.insert(head, at: 0)
                }
                allItems.append(contentsOf: sortedBranches.map { .branch(name: $0) })
                allItems.append(.createBranch)

                items = allItems
                isLoading = false
            }
        }
    }

    // MARK: - Git/GH Operations

    private static func detectHead(directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private static func fetchBranches(directory: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", "--format=%(refname:short)", "--sort=-committerdate"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return [] }
        guard process.terminationStatus == 0 else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func fetchOpenPRs(repoSlug: String) -> [CloudWorkspaceItem] {
        guard let ghPath = resolvedGHPath() else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = [
            "pr", "list",
            "--repo", repoSlug,
            "--state", "open",
            "--limit", "20",
            "--json", "number,title,headRefName",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return [] }
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json.compactMap { item in
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let branch = item["headRefName"] as? String else { return nil }
            return CloudWorkspaceItem.pr(number: number, title: title, branch: branch, repoSlug: repoSlug)
        }
    }

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
