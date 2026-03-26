import Foundation
#if DEBUG
import Bonsplit
#endif

/// Encapsulates all GitHub CLI (`gh`) interactions for pull request data.
///
/// All methods are `nonisolated static` and safe to call from background queues.
/// The service uses the locally installed `gh` CLI for authentication and API access.
enum GitHubService {

    // MARK: - Public types

    struct PullRequestInfo: Equatable {
        let number: Int
        let url: URL
        let status: SidebarPullRequestStatus
        let branch: String
        let title: String?
        let additions: Int?
        let deletions: Int?
        let reviewDecision: SidebarPullRequestReviewDecision?
        let checks: SidebarPullRequestChecksStatus?
        let checksTotal: Int?
        let checksPassed: Int?
    }

    enum LookupResult: Equatable {
        case unsupportedRepository
        case notFound
        case resolved(PullRequestInfo)
        case transientFailure
    }

    // MARK: - Decodable models

    struct PullRequestProbeItem: Decodable, Equatable {
        let number: Int
        let state: String
        let url: String
        let updatedAt: String?
        let title: String?
        let additions: Int?
        let deletions: Int?
        let reviewDecision: String?
    }

    private struct CheckItem: Decodable {
        let bucket: String?
        let state: String?
    }

    struct ChecksResult: Equatable {
        let status: SidebarPullRequestChecksStatus?
        let total: Int
        let passed: Int
    }

    // MARK: - Configuration

    private static let probeTimeout: TimeInterval = 5.0

    // MARK: - Public API

    /// Look up the pull request for a branch across all GitHub remotes in the repo.
    nonisolated static func lookupPullRequest(
        directory: String,
        branch: String
    ) -> LookupResult {
        guard !shouldSkipLookup(branch: branch) else {
            return .notFound
        }

        let repoSlugs = repositorySlugs(directory: directory)
        guard !repoSlugs.isEmpty else {
            return .unsupportedRepository
        }

        var sawTransientFailure = false
        for repoSlug in repoSlugs {
            switch lookupPullRequest(directory: directory, branch: branch, repoSlug: repoSlug) {
            case .resolved(let info):
                return .resolved(info)
            case .transientFailure:
                sawTransientFailure = true
            case .notFound, .unsupportedRepository:
                continue
            }
        }

        return sawTransientFailure ? .transientFailure : .notFound
    }

    /// Look up the pull request for a branch in a specific repo.
    nonisolated static func lookupPullRequest(
        directory: String,
        branch: String,
        repoSlug: String
    ) -> LookupResult {
        let result = runCommandResult(
            directory: directory,
            executable: "gh",
            arguments: [
                "pr", "list",
                "--repo", repoSlug,
                "--state", "all",
                "--head", branch,
                "--json", "number,state,url,updatedAt,title,additions,deletions,reviewDecision",
            ],
            timeout: probeTimeout
        )

        guard let result else {
#if DEBUG
            dlog(
                "github.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=nil"
            )
#endif
            return .transientFailure
        }

        guard !result.timedOut,
              result.executionError == nil,
              let exitStatus = result.exitStatus else {
#if DEBUG
            let statusText: String
            if result.timedOut {
                statusText = "timeout"
            } else if let executionError = result.executionError {
                statusText = "error=\(executionError)"
            } else {
                statusText = "unknown"
            }
            let stderr = debugLogSnippet(result.stderr) ?? "none"
            dlog(
                "github.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=\(statusText) stderr=\(stderr)"
            )
#endif
            return .transientFailure
        }

        if exitStatus != 0 {
#if DEBUG
            dlog(
                "github.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=exit=\(exitStatus) stderr=\(debugLogSnippet(result.stderr) ?? "none")"
            )
#endif
            return .transientFailure
        }

        let output = result.stdout ?? ""
        guard let pullRequests = decodeJSON([PullRequestProbeItem].self, from: output) else {
#if DEBUG
            dlog(
                "github.pr.parseFail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) output=\(debugLogSnippet(output) ?? "none")"
            )
#endif
            return .transientFailure
        }

        guard let pullRequest = preferredPullRequest(from: pullRequests) else {
#if DEBUG
            dlog(
                "github.pr.none dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug)"
            )
#endif
            return .notFound
        }

        guard let status = parseStatus(from: pullRequest.state),
              let url = URL(string: pullRequest.url) else {
#if DEBUG
            dlog(
                "github.pr.parseFail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) output=\(debugLogSnippet(output) ?? "none")"
            )
#endif
            return .transientFailure
        }

        let checksResult = status == .open
            ? fetchChecks(number: pullRequest.number, directory: directory, repoSlug: repoSlug)
            : ChecksResult(status: nil, total: 0, passed: 0)

        let reviewDecision = pullRequest.reviewDecision.flatMap {
            SidebarPullRequestReviewDecision(gitHubValue: $0)
        }

#if DEBUG
        let prDebugMsg = "github.pr.success dir=\(directory) branch=\(branch) repo=\(repoSlug) number=\(pullRequest.number) state=\(status.rawValue)"
        let prDebugDetail = "checks=\(checksResult.status?.rawValue ?? "none") review=\(reviewDecision?.rawValue ?? "nil")"
        dlog("\(prDebugMsg) \(prDebugDetail)")
#endif
        return .resolved(
            PullRequestInfo(
                number: pullRequest.number,
                url: url,
                status: status,
                branch: branch,
                title: pullRequest.title,
                additions: pullRequest.additions,
                deletions: pullRequest.deletions,
                reviewDecision: reviewDecision,
                checks: checksResult.status,
                checksTotal: checksResult.total > 0 ? checksResult.total : nil,
                checksPassed: checksResult.total > 0 ? checksResult.passed : nil
            )
        )
    }

    /// Fetch CI check status with pass/total counts for a PR.
    nonisolated static func fetchChecks(
        number: Int,
        directory: String,
        repoSlug: String
    ) -> ChecksResult {
        let result = runCommandResult(
            directory: directory,
            executable: "gh",
            arguments: [
                "pr", "checks", String(number),
                "--repo", repoSlug,
                "--json", "bucket,state"
            ],
            timeout: probeTimeout
        )

        guard let result,
              !result.timedOut,
              result.executionError == nil,
              let output = result.stdout,
              let exitStatus = result.exitStatus,
              exitStatus == 0 || exitStatus == 8,
              let checks = decodeJSON([CheckItem].self, from: output) else {
            return ChecksResult(status: nil, total: 0, passed: 0)
        }

        var sawPending = false
        var sawPass = false
        var total = 0
        var passed = 0

        for check in checks {
            let bucket = check.bucket?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let state = check.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            total += 1

            if isFailingCheckState(bucket: bucket, state: state) {
                continue
            }
            if isPendingCheckState(bucket: bucket, state: state) {
                sawPending = true
                continue
            }
            if isPassingCheckState(bucket: bucket, state: state) {
                sawPass = true
                passed += 1
            }
        }

        let status: SidebarPullRequestChecksStatus?
        if total == 0 {
            status = nil
        } else if passed < total && !sawPending {
            status = .fail
        } else if sawPending {
            status = .pending
        } else if sawPass {
            status = .pass
        } else {
            status = nil
        }

        return ChecksResult(status: status, total: total, passed: passed)
    }

    // MARK: - PR selection

    nonisolated static func preferredPullRequest(
        from pullRequests: [PullRequestProbeItem]
    ) -> PullRequestProbeItem? {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .open: return 3
            case .merged: return 2
            case .closed: return 1
            }
        }

        func isPreferred(
            candidate: PullRequestProbeItem,
            over current: PullRequestProbeItem
        ) -> Bool {
            guard let candidateStatus = parseStatus(from: candidate.state),
                  let currentStatus = parseStatus(from: current.state) else {
                return false
            }

            let candidatePriority = statusPriority(candidateStatus)
            let currentPriority = statusPriority(currentStatus)
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }

            let candidateUpdatedAt = candidate.updatedAt ?? ""
            let currentUpdatedAt = current.updatedAt ?? ""
            if candidateUpdatedAt != currentUpdatedAt {
                return candidateUpdatedAt > currentUpdatedAt
            }

            return candidate.number > current.number
        }

        var best: PullRequestProbeItem?
        for pullRequest in pullRequests {
            guard parseStatus(from: pullRequest.state) != nil,
                  URL(string: pullRequest.url) != nil else {
                continue
            }
            guard let currentBest = best else {
                best = pullRequest
                continue
            }
            if isPreferred(candidate: pullRequest, over: currentBest) {
                best = pullRequest
            }
        }
        return best
    }

    // MARK: - Repository slugs

    nonisolated static func repositorySlugs(directory: String) -> [String] {
        guard let output = runCommand(directory: directory, executable: "git", arguments: ["remote", "-v"]) else {
            return []
        }
        return repositorySlugs(fromGitRemoteVOutput: output)
    }

    nonisolated static func repositorySlugs(fromGitRemoteVOutput output: String) -> [String] {
        var slugByRemoteName: [String: String] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let remoteName = String(parts[0])
            let remoteURL = String(parts[1])
            let remoteKind = String(parts[2])
            guard remoteKind == "(fetch)",
                  let repoSlug = repositorySlug(fromRemoteURL: remoteURL) else {
                continue
            }

            if slugByRemoteName[remoteName] == nil {
                slugByRemoteName[remoteName] = repoSlug
            }
        }

        let orderedRemoteNames = slugByRemoteName.keys.sorted { lhs, rhs in
            let lhsPriority = remotePriority(lhs)
            let rhsPriority = remotePriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }

        var orderedSlugs: [String] = []
        var seen: Set<String> = []
        for remoteName in orderedRemoteNames {
            guard let repoSlug = slugByRemoteName[remoteName],
                  seen.insert(repoSlug).inserted else {
                continue
            }
            orderedSlugs.append(repoSlug)
        }
        return orderedSlugs
    }

    // MARK: - Helpers

    nonisolated static func shouldSkipLookup(branch: String) -> Bool {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "main", "master":
            return true
        default:
            return false
        }
    }

    nonisolated static func parseStatus(from rawState: String) -> SidebarPullRequestStatus? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN": return .open
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return nil
        }
    }

    // MARK: - Private helpers

    private nonisolated static func remotePriority(_ remoteName: String) -> Int {
        switch remoteName.lowercased() {
        case "upstream": return 0
        case "origin": return 1
        default: return 2
        }
    }

    private nonisolated static func repositorySlug(fromRemoteURL remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let githubPrefixes = [
            "git@github.com:",
            "ssh://git@github.com/",
            "https://github.com/",
            "http://github.com/",
            "git://github.com/",
        ]
        for prefix in githubPrefixes where trimmed.hasPrefix(prefix) {
            let path = String(trimmed.dropFirst(prefix.count))
            return normalizedRepositorySlug(path)
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }

        return normalizedRepositorySlug(url.path)
    }

    private nonisolated static func normalizedRepositorySlug(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    private nonisolated static func isFailingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "fail", "failure", "failed", "error", "timed_out", "timedout",
             "cancel", "cancelled", "canceled", "action_required", "startup_failure":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPendingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "pending", "queued", "in_progress", "requested", "waiting", "expected":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPassingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "pass", "success", "successful", "completed", "neutral", "skipping", "skipped":
            return true
        default:
            return false
        }
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func debugLogSnippet(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(180))
    }

    // MARK: - Command execution

    private struct CommandResult {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

    private nonisolated static let fallbackCommandSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    nonisolated static func resolvedCommandPath(
        executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = fallbackCommandSearchDirectories
    ) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []

        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        if let bundledBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            appendSearchPath(bundledBinPath)
        }
        fallbackDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func runCommand(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> String? {
        let result = runCommandResult(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        guard let result,
              result.exitStatus == 0,
              !result.timedOut else {
            return nil
        }
        return result.stdout
    }

    private nonisolated static func runCommandResult(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        if let resolvedExecutable = resolvedCommandPath(executable: executable) {
            process.executableURL = URL(fileURLWithPath: resolvedExecutable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: String(describing: error)
            )
        }

        if let timeout,
           completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        } else if timeout == nil {
            completion.wait()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            stdout: String(data: stdoutData, encoding: .utf8),
            stderr: String(data: stderrData, encoding: .utf8),
            exitStatus: process.terminationStatus,
            timedOut: false,
            executionError: nil
        )
    }
}
