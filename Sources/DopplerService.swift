import Foundation
#if DEBUG
import Bonsplit
#endif

/// Encapsulates all local Doppler CLI interactions for secrets management.
///
/// All methods are `nonisolated static` and safe to call from background queues.
/// The service uses the locally installed `doppler` CLI for authentication and API access.
enum DopplerService {

    // MARK: - Public types

    struct DopplerProject: Decodable, Equatable {
        let id: String
        let name: String
    }

    struct DopplerConfig: Decodable, Equatable {
        let name: String
        let environment: String
        let project: String
    }

    // MARK: - Configuration

    private static let commandTimeout: TimeInterval = 5.0

    // MARK: - CLI Resolution

    /// Returns the full path to the `doppler` CLI, or `nil` if not installed.
    nonisolated static func resolvedDopplerPath() -> String? {
        GitHubService.resolvedCommandPath(executable: "doppler")
    }

    /// Returns `true` if the `doppler` CLI is available on the local machine.
    nonisolated static func isAvailable() -> Bool {
        resolvedDopplerPath() != nil
    }

    // MARK: - Projects & Configs

    /// List all Doppler projects accessible to the current user.
    nonisolated static func listProjects() -> [DopplerProject] {
        guard let output = runDopplerCommand(arguments: ["projects", "--json"]) else {
            return []
        }
        guard let data = output.data(using: .utf8),
              let projects = try? JSONDecoder().decode([DopplerProject].self, from: data) else {
#if DEBUG
            dlog("doppler.listProjects parseFail output=\(output.prefix(200))")
#endif
            return []
        }
#if DEBUG
        dlog("doppler.listProjects count=\(projects.count)")
#endif
        return projects
    }

    /// List all configs for a given project.
    nonisolated static func listConfigs(project: String) -> [DopplerConfig] {
        guard let output = runDopplerCommand(arguments: ["configs", "--project", project, "--json"]) else {
            return []
        }
        guard let data = output.data(using: .utf8),
              let configs = try? JSONDecoder().decode([DopplerConfig].self, from: data) else {
#if DEBUG
            dlog("doppler.listConfigs parseFail project=\(project) output=\(output.prefix(200))")
#endif
            return []
        }
#if DEBUG
        dlog("doppler.listConfigs project=\(project) count=\(configs.count)")
#endif
        return configs
    }

    // MARK: - Service Tokens

    /// Create a short-lived read-only service token for the given project/config.
    /// Returns the raw token string (`dp.st.xxx`), or `nil` on failure.
    nonisolated static func createServiceToken(
        project: String,
        config: String,
        name: String
    ) -> String? {
        let output = runDopplerCommand(arguments: [
            "configs", "tokens", "create", name,
            "--project", project,
            "--config", config,
            "--access", "read",
            "--max-age", "24h",
            "--plain",
        ])
        guard let token = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
#if DEBUG
            dlog("doppler.createServiceToken FAIL project=\(project) config=\(config) name=\(name)")
#endif
            return nil
        }
#if DEBUG
        dlog("doppler.createServiceToken OK project=\(project) config=\(config) tokenPrefix=\(token.prefix(12))...")
#endif
        return token
    }

    // MARK: - Command Execution

    /// Run a `doppler` CLI command and return stdout, or `nil` on failure.
    private nonisolated static func runDopplerCommand(arguments: [String]) -> String? {
        guard let dopplerPath = resolvedDopplerPath() else {
#if DEBUG
            dlog("doppler.run SKIP: CLI not found")
#endif
            return nil
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: dopplerPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
#if DEBUG
            dlog("doppler.run ERROR: \(error.localizedDescription) args=\(arguments)")
#endif
            return nil
        }

        if completion.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
#if DEBUG
            dlog("doppler.run TIMEOUT args=\(arguments)")
#endif
            return nil
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
#if DEBUG
            let stderrStr = String(data: stderrData, encoding: .utf8)?.prefix(200) ?? ""
            dlog("doppler.run FAIL exit=\(process.terminationStatus) args=\(arguments) stderr=\(stderrStr)")
#endif
            return nil
        }

        return String(data: stdoutData, encoding: .utf8)
    }
}
