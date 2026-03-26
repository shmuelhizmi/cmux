import Foundation

// MARK: - API Client

/// HTTP client for the Daytona sandbox REST API.
/// Docs: https://www.daytona.io/docs/en/tools/api/
struct DaytonaAPI: Sendable {
    let baseURL: URL
    let token: String

    init(token: String, baseURL: URL? = nil) {
        self.token = token
        if let baseURL {
            self.baseURL = baseURL
        } else if let envURL = ProcessInfo.processInfo.environment["DAYTONA_API_URL"],
                  let url = URL(string: envURL) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://app.daytona.io/api")!
        }
    }

    // MARK: - Sandbox Lifecycle

    func createSandbox(request: DaytonaSandboxCreateRequest) async throws -> DaytonaSandbox {
        try await post(path: "/sandbox", body: request)
    }

    func getSandbox(id: String) async throws -> DaytonaSandbox {
        try await get(path: "/sandbox/\(id)")
    }

    func startSandbox(id: String) async throws {
        let _: DaytonaEmptyResponse = try await post(path: "/sandbox/\(id)/start")
        return
    }

    func stopSandbox(id: String) async throws {
        let _: DaytonaEmptyResponse = try await post(path: "/sandbox/\(id)/stop")
        return
    }

    func deleteSandbox(id: String) async throws {
        try await delete(path: "/sandbox/\(id)")
    }

    func archiveSandbox(id: String) async throws {
        let _: DaytonaEmptyResponse = try await post(path: "/sandbox/\(id)/archive")
        return
    }

    // MARK: - SSH Access

    func createSSHAccess(sandboxId: String, expiresInMinutes: Int = 60) async throws -> DaytonaSSHAccess {
        try await post(
            path: "/sandbox/\(sandboxId)/ssh-access",
            queryItems: [URLQueryItem(name: "expiresInMinutes", value: String(expiresInMinutes))]
        )
    }

    func revokeSSHAccess(sandboxId: String) async throws {
        try await delete(path: "/sandbox/\(sandboxId)/ssh-access")
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

    private func post<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
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
            throw DaytonaAPIError.invalidResponse(path: path)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw DaytonaAPIError.httpError(statusCode: http.statusCode, path: path, body: body)
        }
    }

    private static func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, path: String, method: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw DaytonaAPIError.decodeFailed(
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
        // Daytona API uses camelCase JSON keys
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Daytona API uses camelCase JSON keys
        return e
    }()
}

// MARK: - Error

enum DaytonaAPIError: LocalizedError {
    case invalidResponse(path: String)
    case httpError(statusCode: Int, path: String, body: String)
    case decodeFailed(path: String, method: String, type: String, body: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let path):
            return "Daytona: invalid response from \(path)"
        case .httpError(let code, let path, let body):
            return "Daytona \(path) (\(code)): \(body)"
        case .decodeFailed(let path, let method, let type, let body, let underlying):
            return "Daytona \(method) \(path): failed to decode \(type): \(underlying)\nResponse: \(body)"
        }
    }
}

// MARK: - Request Models

/// Request body for `POST /sandbox`.
/// When `snapshot` is set, resource fields (`cpu`, `memory`, `disk`) are omitted
/// because snapshots define their own resources.
struct DaytonaSandboxCreateRequest: Encodable {
    let cpu: Int?
    let memory: Int?
    let disk: Int?
    let env: [String: String]?
    let labels: [String: String]?
    let snapshot: String?
    let language: String?
    let region: String?
    let autostopTimeoutMinutes: Int?

    private enum CodingKeys: String, CodingKey {
        case cpu, memory, disk, env, labels, snapshot, language, region
        case autostopTimeoutMinutes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(env, forKey: .env)
        try container.encodeIfPresent(labels, forKey: .labels)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(autostopTimeoutMinutes, forKey: .autostopTimeoutMinutes)
        // Only include resource fields when NOT using a snapshot
        if snapshot == nil {
            try container.encodeIfPresent(cpu, forKey: .cpu)
            try container.encodeIfPresent(memory, forKey: .memory)
            try container.encodeIfPresent(disk, forKey: .disk)
        }
    }
}

// MARK: - Response Models

struct DaytonaSandbox: Decodable {
    let id: String
    let state: String?
    let snapshot: String?
    let region: String?
    let cpu: Int?
    let memory: Int?
    let disk: Int?
}

struct DaytonaSSHAccess: Decodable {
    let token: String
}

/// Used for endpoints that return 200 with empty or minimal body.
private struct DaytonaEmptyResponse: Decodable {
    init(from decoder: Decoder) throws {
        // Accept any JSON (or empty body)
    }
}
