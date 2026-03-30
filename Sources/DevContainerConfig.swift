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
    /// Shell script generated from Dockerfile RUN/ENV/USER commands.
    /// Runs on the sandbox to replicate the Dockerfile environment.
    var dockerfileSetupScript: String?
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
    var context: String?
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
                var config = try JSONDecoder().decode(DevContainerConfig.self, from: cleaned)

                // When there's a Dockerfile, extract the FROM base image and generate
                // a setup script from the RUN/ENV/USER directives.
                if let dockerfile = config.build?.dockerfile {
                    let devcontainerDir = (path as NSString).deletingLastPathComponent
                    let context = config.build?.context ?? "."
                    let contextDir = (devcontainerDir as NSString).appendingPathComponent(context)
                    let dockerfilePath = (contextDir as NSString).appendingPathComponent(dockerfile)
                    if config.image == nil,
                       let fromImage = extractDockerfileFromImage(atPath: dockerfilePath) {
#if DEBUG
                        dlog("devcontainer.dockerfile.from path=\(dockerfilePath) image=\(fromImage)")
#endif
                        config.image = fromImage
                    }
                    // Parse Dockerfile commands into a setup script
                    if let setupScript = parseDockerfileSetupScript(atPath: dockerfilePath) {
#if DEBUG
                        dlog("devcontainer.dockerfile.setupScript lines=\(setupScript.components(separatedBy: .newlines).count)")
#endif
                        config.dockerfileSetupScript = setupScript
                    }
                }

                return config
            } catch {
#if DEBUG
                dlog("devcontainer.parse error path=\(path) err=\(error.localizedDescription)")
#endif
                continue
            }
        }
        return nil
    }

    /// Parses a Dockerfile and generates a shell setup script from its RUN, ENV, USER, and WORKDIR
    /// directives. Root-phase commands are wrapped in `sudo bash`, user-phase commands run directly.
    /// Hardcoded user home paths (e.g. `/home/vscode`) are replaced with `$HOME`.
    static func parseDockerfileSetupScript(atPath path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        struct Directive {
            enum Kind { case run, user, env, workdir }
            let kind: Kind
            let content: String
        }

        // Parse Dockerfile into directives
        var directives: [Directive] = []
        let rawLines = content.components(separatedBy: .newlines)
        var i = 0
        while i < rawLines.count {
            var line = rawLines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            // Skip comments and empty lines
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Handle multi-line continuations
            while line.hasSuffix("\\") && i < rawLines.count {
                line = String(line.dropLast()) + " " + rawLines[i].trimmingCharacters(in: .whitespaces)
                i += 1
            }

            let upper = line.uppercased()
            if upper.hasPrefix("RUN ") {
                directives.append(Directive(kind: .run, content: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
            } else if upper.hasPrefix("USER ") {
                directives.append(Directive(kind: .user, content: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)))
            } else if upper.hasPrefix("ENV ") {
                directives.append(Directive(kind: .env, content: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
            } else if upper.hasPrefix("WORKDIR ") {
                directives.append(Directive(kind: .workdir, content: String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)))
            }
            // Skip FROM, COPY, ADD, CMD, ENTRYPOINT, EXPOSE, LABEL, ARG
        }

        guard !directives.isEmpty else { return nil }

        // Detect the non-root username from USER directives (to replace home paths)
        let nonRootUser = directives.first(where: { $0.kind == .user && $0.content != "root" })?.content

        // Build the setup script
        var currentUser = "root"
        var rootCommands: [String] = []
        var userCommands: [String] = []

        func replaceHomePaths(_ cmd: String) -> String {
            guard let user = nonRootUser else { return cmd }
            return cmd.replacingOccurrences(of: "/home/\(user)", with: "$HOME")
        }

        for directive in directives {
            switch directive.kind {
            case .user:
                currentUser = directive.content
            case .env:
                let replaced = replaceHomePaths(directive.content)
                if currentUser == "root" {
                    rootCommands.append("export \(replaced)")
                } else {
                    userCommands.append("export \(replaced)")
                }
            case .workdir:
                let replaced = replaceHomePaths(directive.content)
                if currentUser == "root" {
                    rootCommands.append("mkdir -p \(replaced) && cd \(replaced)")
                } else {
                    userCommands.append("mkdir -p \(replaced) 2>/dev/null; cd \(replaced)")
                }
            case .run:
                let replaced = replaceHomePaths(directive.content)
                if currentUser == "root" {
                    rootCommands.append(replaced)
                } else {
                    userCommands.append(replaced)
                }
            }
        }

        var script = "#!/bin/bash\nset -e\nexport DEBIAN_FRONTEND=noninteractive\n"
        script += "echo \"Setting up dev container environment...\"\n\n"

        if !rootCommands.isEmpty {
            script += "# Root-phase commands from Dockerfile\n"
            script += "sudo bash <<'__DEVCONTAINER_ROOT__'\n"
            script += "set -e\nexport DEBIAN_FRONTEND=noninteractive\n"
            script += rootCommands.joined(separator: "\n")
            script += "\n__DEVCONTAINER_ROOT__\n\n"
        }

        if !userCommands.isEmpty {
            script += "# User-phase commands from Dockerfile\n"
            script += userCommands.joined(separator: "\n")
            script += "\n\n"
        }

        script += "echo \"Dev container setup complete\""
        return script
    }

    /// Extracts the base image from a Dockerfile's first `FROM` instruction.
    private static func extractDockerfileFromImage(atPath path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("FROM ") else { continue }
            // FROM image:tag [AS name]
            let parts = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
            guard let image = parts.first, !image.isEmpty else { continue }
            // Skip ARG-based images like FROM ${BASE_IMAGE}
            if image.contains("$") { return nil }
            return image
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
