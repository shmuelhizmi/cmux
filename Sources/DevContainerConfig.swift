import Foundation
#if DEBUG
import Bonsplit
#endif

/// Minimal parser for `.devcontainer/devcontainer.json` files.
/// Extracts the fields relevant to Daytona sandbox creation.
struct DevContainerConfig: Codable, Equatable, Sendable {
    var image: String?
    var containerEnv: [String: String]?
    var remoteEnv: [String: String]?
    var postCreateCommand: DevContainerCommand?
    var build: DevContainerBuild?
}

// MARK: - Nested Types

/// `postCreateCommand` in devcontainer.json can be a string, an array of strings,
/// or an object mapping names to commands.
enum DevContainerCommand: Equatable, Sendable {
    case string(String)
    case array([String])
    case object([String: String])

    /// Returns a single shell command string suitable for execution.
    var shellString: String {
        switch self {
        case .string(let s):
            return s
        case .array(let parts):
            return parts.joined(separator: " ")
        case .object(let map):
            // Run each named command sequentially
            return map.values.joined(separator: " && ")
        }
    }
}

extension DevContainerCommand: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([String].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: String].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                DevContainerCommand.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string, [string], or {string: string}")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}

struct DevContainerBuild: Codable, Equatable, Sendable {
    var dockerfile: String?
}

// MARK: - Detection

extension DevContainerConfig {
    /// Searches for a devcontainer.json in the given directory and parses it.
    /// Checks `.devcontainer/devcontainer.json` first, then `.devcontainer.json` at root.
    static func detect(inDirectory directory: String) -> DevContainerConfig? {
        let fm = FileManager.default
        let candidates = [
            (directory as NSString).appendingPathComponent(".devcontainer/devcontainer.json"),
            (directory as NSString).appendingPathComponent(".devcontainer.json"),
        ]

        for path in candidates {
            guard fm.fileExists(atPath: path),
                  let data = fm.contents(atPath: path) else {
                continue
            }
            // devcontainer.json allows JSON5-style comments; strip them before parsing
            guard let cleaned = stripJSONComments(data) else { continue }
            do {
                return try JSONDecoder().decode(DevContainerConfig.self, from: cleaned)
            } catch {
#if DEBUG
                dlog("devcontainer.parse error path=\(path) err=\(error.localizedDescription)")
#endif
                continue
            }
        }
        return nil
    }

    /// Strips `//` line comments and `/* */` block comments from JSON5-style content.
    private static func stripJSONComments(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var result = ""
        result.reserveCapacity(text.count)
        var i = text.startIndex
        let end = text.endIndex

        while i < end {
            let c = text[i]

            // Skip strings (preserve their contents)
            if c == "\"" {
                result.append(c)
                i = text.index(after: i)
                while i < end {
                    let sc = text[i]
                    result.append(sc)
                    if sc == "\\" {
                        // Skip escaped character
                        i = text.index(after: i)
                        if i < end {
                            result.append(text[i])
                            i = text.index(after: i)
                        }
                    } else if sc == "\"" {
                        i = text.index(after: i)
                        break
                    } else {
                        i = text.index(after: i)
                    }
                }
                continue
            }

            // Check for comments
            if c == "/" {
                let next = text.index(after: i)
                if next < end {
                    if text[next] == "/" {
                        // Line comment — skip until newline
                        i = text.index(after: next)
                        while i < end && text[i] != "\n" {
                            i = text.index(after: i)
                        }
                        continue
                    } else if text[next] == "*" {
                        // Block comment — skip until */
                        i = text.index(next, offsetBy: 1)
                        while i < end {
                            if text[i] == "*" {
                                let afterStar = text.index(after: i)
                                if afterStar < end && text[afterStar] == "/" {
                                    i = text.index(after: afterStar)
                                    break
                                }
                            }
                            i = text.index(after: i)
                        }
                        continue
                    }
                }
            }

            result.append(c)
            i = text.index(after: i)
        }

        return result.data(using: .utf8)
    }
}
