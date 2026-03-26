import Foundation

// MARK: - API Client

/// Minimal HTTP client for the fly.io Machines REST API.
/// Docs: https://fly.io/docs/machines/api/machines-resource/
struct FlyMachinesAPI: Sendable {
    let baseURL: URL
    let token: String

    init(token: String, baseURL: URL = URL(string: "https://api.machines.dev")!) {
        self.token = token
        self.baseURL = baseURL
    }

    // MARK: - App Management

    func createApp(name: String, org: String = "personal") async throws {
        let body = FlyAppCreateRequest(appName: name, orgSlug: org)
        let _: FlyEmptyResponse = try await post(path: "/v1/apps", body: body)
    }

    /// Creates the app if it doesn't exist. Ignores "already exists" errors.
    func ensureAppExists(name: String) async throws {
        do {
            try await createApp(name: name)
        } catch let error as FlyAPIError {
            // 422 = app already exists, which is fine
            if case .httpError(let code, _, _) = error, code == 422 {
                return
            }
            throw error
        }
    }

    // MARK: - Machine Lifecycle

    func createMachine(app: String, config: FlyMachineCreateRequest) async throws -> FlyMachine {
        try await post(path: "/v1/apps/\(app)/machines", body: config)
    }

    func getMachine(app: String, machineID: String) async throws -> FlyMachine {
        try await get(path: "/v1/apps/\(app)/machines/\(machineID)")
    }

    func startMachine(app: String, machineID: String) async throws {
        let _: FlyEmptyResponse = try await post(path: "/v1/apps/\(app)/machines/\(machineID)/start")
        return
    }

    func stopMachine(app: String, machineID: String) async throws {
        let _: FlyEmptyResponse = try await post(path: "/v1/apps/\(app)/machines/\(machineID)/stop")
        return
    }

    func destroyMachine(app: String, machineID: String, force: Bool = false) async throws {
        var path = "/v1/apps/\(app)/machines/\(machineID)"
        if force { path += "?force=true" }
        try await delete(path: path)
    }

    /// Long-polls until the machine reaches the target state.
    /// The server blocks up to `timeout` seconds before returning.
    func waitForState(
        app: String,
        machineID: String,
        state: String,
        timeout: Int = 60
    ) async throws {
        let _: FlyWaitResponse = try await get(
            path: "/v1/apps/\(app)/machines/\(machineID)/wait",
            queryItems: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "timeout", value: String(timeout)),
            ]
        )
    }

    // MARK: - Volumes

    func createVolume(app: String, request: FlyVolumeCreateRequest) async throws -> FlyVolume {
        try await post(path: "/v1/apps/\(app)/volumes", body: request)
    }

    func listVolumes(app: String) async throws -> [FlyVolume] {
        try await get(path: "/v1/apps/\(app)/volumes")
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data, path: path)
        return try Self.decodeResponse(T.self, from: data, path: path, method: "GET")
    }

    private func post<B: Encodable, T: Decodable>(
        path: String,
        body: B
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data, path: path)
        return try Self.decodeResponse(T.self, from: data, path: path, method: "POST")
    }

    private func post<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data, path: path)
        return try Self.decodeResponse(T.self, from: data, path: path, method: "POST")
    }

    private func delete(path: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkResponse(response, data: data, path: path)
    }

    private static func checkResponse(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FlyAPIError.invalidResponse(path: path)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw FlyAPIError.httpError(statusCode: http.statusCode, path: path, body: body)
        }
    }

    private static func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, path: String, method: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw FlyAPIError.decodeFailed(
                path: path,
                method: method,
                type: String(describing: type),
                body: bodyPreview,
                underlying: error.localizedDescription
            )
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

// MARK: - Error

enum FlyAPIError: LocalizedError {
    case invalidResponse(path: String)
    case httpError(statusCode: Int, path: String, body: String)
    case decodeFailed(path: String, method: String, type: String, body: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let path):
            return "fly.io: invalid response from \(path)"
        case .httpError(let code, let path, let body):
            return "fly.io \(path) (\(code)): \(body)"
        case .decodeFailed(let path, let method, let type, let body, let underlying):
            return "fly.io \(method) \(path): failed to decode \(type): \(underlying)\nResponse: \(body)"
        }
    }
}

// MARK: - Request Models

struct FlyAppCreateRequest: Encodable {
    let appName: String
    let orgSlug: String
}

struct FlyMachineCreateRequest: Encodable {
    let name: String?
    let region: String?
    let config: Config

    struct Config: Encodable {
        let image: String
        let guest: Guest
        let env: [String: String]?
        let `init`: Init?
        let mounts: [Mount]?
        let services: [Service]?

        struct Guest: Encodable {
            let cpuKind: String
            let cpus: Int
            let memoryMb: Int
        }

        struct Init: Encodable {
            let exec: [String]?
        }

        struct Mount: Encodable {
            let volume: String
            let path: String
        }

        struct Service: Encodable {
            let ports: [Port]
            let internalPort: Int
            let `protocol`: String

            struct Port: Encodable {
                let port: Int
                let handlers: [String]?
            }
        }
    }
}

struct FlyVolumeCreateRequest: Encodable {
    let name: String
    let region: String
    let sizeGb: Int
}

// MARK: - Response Models

struct FlyMachine: Decodable {
    let id: String
    let name: String?
    let state: String?
    let region: String?
    let privateIp: String?
    let config: Config?

    struct Config: Decodable {
        let image: String?
        let guest: Guest?

        struct Guest: Decodable {
            let cpuKind: String?
            let cpus: Int?
            let memoryMb: Int?
        }
    }
}

struct FlyVolume: Decodable {
    let id: String
    let name: String?
    let state: String?
    let region: String?
    let sizeGb: Int?
    let attachedMachineId: String?
    let attachedAllocId: String?
}

/// Response from the /wait endpoint — different shape from FlyMachine.
struct FlyWaitResponse: Decodable {
    let ok: Bool?
    let state: String?
    let eventId: String?
    let version: String?
}

/// Used for endpoints that return 200 with empty or minimal body.
private struct FlyEmptyResponse: Decodable {
    init(from decoder: Decoder) throws {
        // Accept any JSON (or empty body)
    }
}
