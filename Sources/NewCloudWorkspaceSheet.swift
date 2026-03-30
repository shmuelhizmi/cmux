import SwiftUI
#if DEBUG
import Bonsplit
#endif

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
    var onSubmit: (DaytonaCloudConfiguration, String?) -> Void
    var onLocalWorkspace: () -> Void
    var onDismiss: (() -> Void)?
    var externalError: String?

    @State private var searchText: String = ""
    @State private var items: [CloudWorkspaceItem] = []
    @State private var isLoading: Bool = true
    @State private var selectedIndex: Int = 0
    @State private var detectedRepoSlug: String?
    @State private var detectedRepoURL: String?
    @State private var detectedHead: String?
    @State private var showCreateBranchInput: Bool = false
    @State private var newBranchName: String = ""
    @State private var newBranchBase: String = "main"
    @State private var errorMessage: String?
    @State private var needsApiKey: Bool = DaytonaAuthTokenStore.token() == nil
    @State private var apiKeyInput: String = ""
    @State private var detectedDevContainer: DevContainerConfig?
    @State private var githubToken: String?
    @State private var showMachineSettings: Bool = false
    @State private var existingSandboxes: [DaytonaSandbox] = []
    @State private var isLoadingSandboxes: Bool = false
    @State private var showExistingSandboxes: Bool = false

    // Doppler integration
    @State private var isDopplerAvailable: Bool = false
    @State private var showDopplerSettings: Bool = false
    @State private var dopplerMode: Int = 0 // 0 = project/config, 1 = manual token
    @State private var dopplerProjects: [DopplerService.DopplerProject] = []
    @State private var dopplerConfigs: [DopplerService.DopplerConfig] = []
    @State private var selectedDopplerProject: String? = nil
    @State private var selectedDopplerConfig: String? = nil
    @State private var dopplerTokenInput: String = ""
    @State private var isLoadingDopplerProjects: Bool = false
    @State private var isLoadingDopplerConfigs: Bool = false

    @AppStorage(CloudMachineSettings.cpuKey) private var cpuSetting = CloudMachineSettings.defaultCPU
    @AppStorage(CloudMachineSettings.memoryKey) private var memorySetting = CloudMachineSettings.defaultMemory
    @AppStorage(CloudMachineSettings.diskKey) private var diskSetting = CloudMachineSettings.defaultDisk

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

            if needsApiKey {
                apiKeyInputSection
            }

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

                // Error display
                if let displayError = externalError ?? errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red.opacity(0.8))
                            .font(.system(size: 11))
                        Text(displayError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                }

                Divider()

                // Machine settings
                machineSettingsSection

                // Doppler secrets
                dopplerSettingsSection

                // Existing sandboxes
                existingSandboxesSection

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
            loadExistingSandboxes()
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
#if DEBUG
                dlog("cloud.modal.keyMonitor ENTER -> selectCurrentItem")
#endif
                selectCurrentItem()
                return nil
            case Self.kVKEscape:
#if DEBUG
                dlog("cloud.modal.keyMonitor ESC -> dismiss")
#endif
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

    // MARK: - API Key Input

    private var apiKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "cloud.apiKey.title", defaultValue: "Daytona API Key"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField(
                    String(localized: "cloud.apiKey.placeholder", defaultValue: "Paste your API key..."),
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { saveApiKey() }
                Button(String(localized: "cloud.apiKey.save", defaultValue: "Save")) {
                    saveApiKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(String(localized: "cloud.apiKey.hint", defaultValue: "Get your key at app.daytona.io. Stored securely in Keychain."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if DaytonaAuthTokenStore.setToken(key) {
            needsApiKey = false
            apiKeyInput = ""
        } else {
            errorMessage = String(localized: "cloud.apiKey.error", defaultValue: "Failed to store API key in Keychain")
        }
    }

    // MARK: - Machine Settings

    private var machineSettingsSection: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMachineSettings.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showMachineSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Text(String(localized: "cloud.machine.title", defaultValue: "Machine"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(machineSettingSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMachineSettings {
                VStack(spacing: 10) {
                    stepSlider(
                        label: String(localized: "cloud.machine.cpu", defaultValue: "CPU"),
                        value: $cpuSetting,
                        steps: CloudMachineSettings.cpuSteps,
                        unit: String(localized: "cloud.machine.cores", defaultValue: "cores")
                    )
                    stepSlider(
                        label: String(localized: "cloud.machine.memory", defaultValue: "Memory"),
                        value: $memorySetting,
                        steps: CloudMachineSettings.memorySteps,
                        unit: "GB"
                    )
                    stepSlider(
                        label: String(localized: "cloud.machine.disk", defaultValue: "Disk"),
                        value: $diskSetting,
                        steps: CloudMachineSettings.diskSteps,
                        unit: "GB"
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var machineSettingSummary: String {
        "\(cpuSetting) CPU · \(memorySetting) GB · \(diskSetting) GB"
    }

    private func stepSlider(label: String, value: Binding<Int>, steps: [Int], unit: String) -> some View {
        let idx = steps.firstIndex(of: value.wrappedValue) ?? 0
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Slider(
                value: Binding<Double>(
                    get: { Double(idx) },
                    set: { newIdx in
                        let clamped = max(0, min(steps.count - 1, Int(newIdx.rounded())))
                        value.wrappedValue = steps[clamped]
                    }
                ),
                in: 0...Double(steps.count - 1),
                step: 1
            )
            Text("\(value.wrappedValue) \(unit)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 65, alignment: .trailing)
        }
    }

    // MARK: - Existing Sandboxes

    private var existingSandboxesSection: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showExistingSandboxes.toggle()
                    if showExistingSandboxes && existingSandboxes.isEmpty && !isLoadingSandboxes {
                        loadExistingSandboxes()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showExistingSandboxes ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Text(String(localized: "cloud.sandboxes.title", defaultValue: "Existing Sandboxes"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isLoadingSandboxes {
                        ProgressView()
                            .controlSize(.mini)
                    } else if !existingSandboxes.isEmpty {
                        Text("\(existingSandboxes.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showExistingSandboxes {
                ScrollView {
                    VStack(spacing: 2) {
                        if existingSandboxes.isEmpty && !isLoadingSandboxes {
                            Text(String(localized: "cloud.sandboxes.empty", defaultValue: "No existing sandboxes"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(existingSandboxes) { sandbox in
                                sandboxRow(sandbox)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .frame(height: min(CGFloat(max(existingSandboxes.count, 1)) * 44, 150))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sandboxRow(_ sandbox: DaytonaSandbox) -> some View {
        HStack(spacing: 8) {
            // State indicator
            Circle()
                .fill(sandboxStateColor(sandbox.state))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(sandbox.id.prefix(12) + "...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(sandbox.state ?? "unknown")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let image = sandbox.image {
                        Text(image.components(separatedBy: "/").last ?? image)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if let snapshot = sandbox.snapshot {
                        Text(snapshot)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Actions
            if sandbox.state == "stopped" || sandbox.state == "archived" {
                Button {
                    deleteSandbox(sandbox.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(String(localized: "cloud.sandboxes.delete", defaultValue: "Delete sandbox"))
            } else if sandbox.state == "running" || sandbox.state == "started" {
                Button {
                    stopSandbox(sandbox.id)
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(String(localized: "cloud.sandboxes.stop", defaultValue: "Stop sandbox"))

                Button {
                    deleteSandbox(sandbox.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(String(localized: "cloud.sandboxes.delete", defaultValue: "Delete sandbox"))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.08))
        )
    }

    private func sandboxStateColor(_ state: String?) -> Color {
        switch state {
        case "running", "started": return .green
        case "stopped", "archived": return .gray
        case "creating", "starting": return .yellow
        case "error": return .red
        default: return .gray.opacity(0.5)
        }
    }

    private func loadExistingSandboxes() {
        guard let token = DaytonaAuthTokenStore.token() else { return }
        isLoadingSandboxes = true
        let api = DaytonaAPI(token: token)
        Task {
            do {
                let all = try await api.listSandboxes()
#if DEBUG
                dlog("cloud.sandboxes.loaded total=\(all.count)")
                for sb in all {
                    dlog("cloud.sandboxes.item id=\(sb.id.prefix(12)) state=\(sb.state ?? "nil") labels=\(sb.labels ?? [:])")
                }
#endif
                // Only show sandboxes created by cmux (tagged with cmux label)
                let cmuxSandboxes = all.filter { $0.labels?["cmux"] != nil }
#if DEBUG
                dlog("cloud.sandboxes.filtered cmux=\(cmuxSandboxes.count)")
#endif
                await MainActor.run {
                    existingSandboxes = cmuxSandboxes
                    isLoadingSandboxes = false
                }
            } catch {
#if DEBUG
                dlog("cloud.sandboxes.loadError: \(error.localizedDescription)")
#endif
                await MainActor.run {
                    isLoadingSandboxes = false
                }
            }
        }
    }

    private func stopSandbox(_ id: String) {
        guard let token = DaytonaAuthTokenStore.token() else { return }
        let api = DaytonaAPI(token: token)
        Task {
            do {
                try await api.stopSandbox(id: id)
                // Refresh the list
                loadExistingSandboxes()
            } catch {
#if DEBUG
                dlog("cloud.sandboxes.stopError id=\(id): \(error.localizedDescription)")
#endif
            }
        }
    }

    private func deleteSandbox(_ id: String) {
        guard let token = DaytonaAuthTokenStore.token() else { return }
        let api = DaytonaAPI(token: token)
        // Optimistically remove from UI
        existingSandboxes.removeAll { $0.id == id }
        Task {
            do {
                try await api.deleteSandbox(id: id)
            } catch {
#if DEBUG
                dlog("cloud.sandboxes.deleteError id=\(id): \(error.localizedDescription)")
#endif
                // Refresh to restore state
                loadExistingSandboxes()
            }
        }
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
#if DEBUG
        dlog("cloud.modal.selectCurrentItem index=\(selectedIndex) count=\(items.count)")
#endif
        guard selectedIndex >= 0, selectedIndex < items.count else {
#if DEBUG
            dlog("cloud.modal.selectCurrentItem SKIP: index out of range")
#endif
            return
        }
        selectItem(items[selectedIndex])
    }

    private func selectItem(_ item: CloudWorkspaceItem) {
#if DEBUG
        dlog("cloud.modal.selectItem id=\(item.id)")
#endif
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
#if DEBUG
        dlog("cloud.modal.submitBranch name=\(name) repoSlug=\(detectedRepoSlug ?? "nil") repoURL=\(detectedRepoURL ?? "nil")")
#endif
        guard let repoURL = effectiveRepoURL() else {
#if DEBUG
            dlog("cloud.modal.submitBranch FAIL: no repo URL")
#endif
            return
        }
        let script = DaytonaCloudConfiguration.buildGitSetupScript(
            mode: "import_branch", repoURL: repoURL, branchName: name,
            githubToken: githubToken
        )
        guard let config = buildConfig(gitSetupScript: script) else { return }
#if DEBUG
        dlog("cloud.modal.submitBranch calling onSubmit appName=\(config.sandboxSpec.snapshot ?? "default")")
#endif
        onSubmit(config, name)
    }

    private func submitPR(number: Int, title: String, repoSlug: String) {
#if DEBUG
        dlog("cloud.modal.submitPR number=\(number) slug=\(repoSlug) repoURL=\(detectedRepoURL ?? "nil")")
#endif
        guard let repoURL = effectiveRepoURL() else {
#if DEBUG
            dlog("cloud.modal.submitPR FAIL: no repo URL")
#endif
            return
        }
        let script = DaytonaCloudConfiguration.buildGitSetupScript(
            mode: "import_pr", repoURL: repoURL, prNumber: number, repoSlug: repoSlug,
            githubToken: githubToken
        )
        let label = "#\(number) \(title)"
        guard let config = buildConfig(gitSetupScript: script) else { return }
#if DEBUG
        dlog("cloud.modal.submitPR calling onSubmit appName=\(config.sandboxSpec.snapshot ?? "default")")
#endif
        onSubmit(config, label)
    }

    private func submitCreateBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let repoURL = effectiveRepoURL() else { return }
        let base = newBranchBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = DaytonaCloudConfiguration.buildGitSetupScript(
            mode: "create_branch", repoURL: repoURL,
            baseBranch: base.isEmpty ? "main" : base,
            newBranchName: name,
            githubToken: githubToken
        )
        guard let config = buildConfig(gitSetupScript: script) else { return }
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

    private func buildConfig(gitSetupScript: String) -> DaytonaCloudConfiguration? {
        var dopplerCfg: DopplerIntegrationConfig?
        if showDopplerSettings {
            if dopplerMode == 1 {
                let token = dopplerTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    dopplerCfg = DopplerIntegrationConfig(serviceToken: token, project: nil, config: nil)
                }
            } else if let project = selectedDopplerProject, let config = selectedDopplerConfig {
                let tokenName = "cmux-\(Int(Date().timeIntervalSince1970))"
                if let token = DopplerService.createServiceToken(project: project, config: config, name: tokenName) {
                    dopplerCfg = DopplerIntegrationConfig(serviceToken: token, project: project, config: config)
                } else {
                    errorMessage = String(localized: "cloud.doppler.tokenCreateFail", defaultValue: "Failed to create Doppler service token")
                    return nil
                }
            }
        }
        return DaytonaCloudConfiguration(
            sandboxSpec: .fromSettings(),
            gitSetupScript: gitSetupScript,
            autoStopInterval: 1440,
            devContainer: detectedDevContainer,
            doppler: dopplerCfg
        )
    }

    // MARK: - Doppler Settings

    private var dopplerSettingsSection: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showDopplerSettings.toggle()
                    if showDopplerSettings && dopplerMode == 0 && dopplerProjects.isEmpty && !isLoadingDopplerProjects {
                        loadDopplerProjects()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showDopplerSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Text(String(localized: "cloud.doppler.title", defaultValue: "Secrets"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(dopplerSettingSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDopplerSettings {
                VStack(spacing: 10) {
                    Picker("", selection: $dopplerMode) {
                        Text(String(localized: "cloud.doppler.projectConfig", defaultValue: "Project / Config")).tag(0)
                        Text(String(localized: "cloud.doppler.serviceToken", defaultValue: "Service Token")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: dopplerMode) { _, newValue in
                        if newValue == 0 && dopplerProjects.isEmpty && !isLoadingDopplerProjects {
                            loadDopplerProjects()
                        }
                    }

                    if dopplerMode == 0 {
                        if !isDopplerAvailable {
                            Text(String(localized: "cloud.doppler.installHint", defaultValue: "Install the doppler CLI to select project/config"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 8) {
                                Text(String(localized: "cloud.doppler.project", defaultValue: "Project"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                if isLoadingDopplerProjects {
                                    ProgressView().controlSize(.small)
                                    Spacer()
                                } else {
                                    Picker("", selection: Binding(
                                        get: { selectedDopplerProject ?? "" },
                                        set: { newValue in
                                            selectedDopplerProject = newValue.isEmpty ? nil : newValue
                                            selectedDopplerConfig = nil
                                            dopplerConfigs = []
                                            if !newValue.isEmpty {
                                                loadDopplerConfigs(project: newValue)
                                            }
                                        }
                                    )) {
                                        Text("--").tag("")
                                        ForEach(dopplerProjects, id: \.id) { project in
                                            Text(project.name).tag(project.name)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }

                            HStack(spacing: 8) {
                                Text(String(localized: "cloud.doppler.config", defaultValue: "Config"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                if isLoadingDopplerConfigs {
                                    ProgressView().controlSize(.small)
                                    Spacer()
                                } else {
                                    Picker("", selection: Binding(
                                        get: { selectedDopplerConfig ?? "" },
                                        set: { selectedDopplerConfig = $0.isEmpty ? nil : $0 }
                                    )) {
                                        Text("--").tag("")
                                        ForEach(dopplerConfigs, id: \.name) { config in
                                            Text(config.name).tag(config.name)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .disabled(selectedDopplerProject == nil)
                                }
                            }
                        }
                    } else {
                        SecureField(
                            String(localized: "cloud.doppler.tokenPlaceholder", defaultValue: "Paste service token (dp.st.xxx)..."),
                            text: $dopplerTokenInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var dopplerSettingSummary: String {
        if !showDopplerSettings {
            return String(localized: "cloud.doppler.disabled", defaultValue: "Disabled")
        }
        if dopplerMode == 1 {
            let token = dopplerTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty
                ? String(localized: "cloud.doppler.disabled", defaultValue: "Disabled")
                : String(localized: "cloud.doppler.tokenSet", defaultValue: "Token")
        }
        if let project = selectedDopplerProject, let config = selectedDopplerConfig {
            return "\(project) / \(config)"
        }
        return String(localized: "cloud.doppler.disabled", defaultValue: "Disabled")
    }

    private func loadDopplerProjects() {
        guard isDopplerAvailable else { return }
        isLoadingDopplerProjects = true
        DispatchQueue.global(qos: .userInitiated).async {
            let projects = DopplerService.listProjects()
            DispatchQueue.main.async {
                dopplerProjects = projects
                isLoadingDopplerProjects = false
            }
        }
    }

    private func loadDopplerConfigs(project: String) {
        isLoadingDopplerConfigs = true
        DispatchQueue.global(qos: .userInitiated).async {
            let configs = DopplerService.listConfigs(project: project)
            DispatchQueue.main.async {
                dopplerConfigs = configs
                isLoadingDopplerConfigs = false
            }
        }
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

            // Detect devcontainer config
            let devContainer = DevContainerConfig.detect(inDirectory: dir)

            // Get GitHub token for private repo auth
            let ghToken = Self.fetchGitHubToken()

            // Check if Doppler CLI is available locally
            let dopplerAvailable = DopplerService.isAvailable()

            DispatchQueue.main.async {
                detectedRepoSlug = slug
                detectedRepoURL = repoURL
                detectedHead = head
                detectedDevContainer = devContainer
                githubToken = ghToken
                isDopplerAvailable = dopplerAvailable

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

    /// Fetches a GitHub auth token via `gh auth token` for use in remote git operations.
    private static func fetchGitHubToken() -> String? {
        guard let ghPath = resolvedGHPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
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
