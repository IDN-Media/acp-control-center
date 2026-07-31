import Foundation

/// Reads the currently configured Xcode ACP wrapper: resolves the wrapper
/// path from the Xcode ACP plist, then parses the wrapper script as text
/// (never executes it as an agent).
struct ACPWrapperReader: Sendable {
    /// Default Xcode ACP definitions directory:
    /// `~/Library/Developer/Xcode/CodingAssistant/ACP`.
    static func defaultACPDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Developer")
            .appendingPathComponent("Xcode")
            .appendingPathComponent("CodingAssistant")
            .appendingPathComponent("ACP")
    }

    private let acpDirectory: URL
    private let processRunner: ProcessRunner

    init(
        acpDirectory: URL? = nil,
        processRunner: ProcessRunner = ProcessRunner()
    ) {
        self.acpDirectory = acpDirectory ?? Self.defaultACPDirectory()
        self.processRunner = processRunner
    }

    /// Reads the Kiro ACP plist when identifiable, otherwise the first plist
    /// in deterministic filename order. Returns `.missing` if no
    /// plist/wrapper is found and `.invalid` if a wrapper cannot be parsed.
    func readWrapperConfiguration() -> Result<ACPWrapperConfiguration, ReaderError> {
        guard let wrapperURL = resolveWrapperURL() else {
            return .failure(.missing(reason: "No ACP plist with an agent path found under \(acpDirectory.path)"))
        }
        return readWrapperConfiguration(atWrapperURL: wrapperURL)
    }

    /// Reads a wrapper at an explicit URL. Exposed separately so tests can
    /// exercise wrapper parsing without needing a plist fixture.
    func readWrapperConfiguration(atWrapperURL wrapperURL: URL) -> Result<ACPWrapperConfiguration, ReaderError> {
        guard let contents = try? String(contentsOf: wrapperURL, encoding: .utf8) else {
            return .failure(.missing(reason: "Wrapper file not found or unreadable at \(wrapperURL.path)"))
        }

        guard let cliExecutableURL = Self.extractExecutable(fromWrapperContents: contents) else {
            return .failure(.invalid(reason: "Could not locate an executable invoked with 'acp' in wrapper"))
        }

        let modelID = Self.extractFlagValue(named: "--model", fromWrapperContents: contents)
        let effort = Self.extractFlagValue(named: "--effort", fromWrapperContents: contents)
        let isExecutable = FileManager.default.isExecutableFile(atPath: wrapperURL.path)
        let syntaxIsValid = checkZshSyntax(of: wrapperURL)

        return .success(
            ACPWrapperConfiguration(
                wrapperURL: wrapperURL,
                cliExecutableURL: cliExecutableURL,
                modelID: modelID,
                effort: effort,
                isExecutable: isExecutable,
                syntaxIsValid: syntaxIsValid
            )
        )
    }

    // MARK: - Plist resolution

    /// Reads the first `.plist` in the ACP directory and extracts its
    /// `agent` string as a file URL.
    private func resolveWrapperURL() -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: acpDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let plistURLs = entries
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var candidates: [(isKiro: Bool, agentURL: URL)] = []
        for plistURL in plistURLs {
            guard let data = try? Data(contentsOf: plistURL) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }
            guard let agentPath = plist["agent"] as? String, !agentPath.isEmpty else { continue }

            let name = (plist["name"] as? String)?.lowercased() ?? ""
            let isKiro = name.contains("kiro") || agentPath.lowercased().contains("kiro")
            candidates.append((isKiro: isKiro, agentURL: URL(fileURLWithPath: agentPath)))
        }

        // Prefer an explicitly Kiro-named ACP definition. If no provider can
        // be identified, deterministic filename ordering provides a stable
        // fallback rather than relying on filesystem enumeration order.
        return candidates.first(where: \.isKiro)?.agentURL ?? candidates.first?.agentURL
    }

    // MARK: - Wrapper text parsing

    /// Extracts the executable from a narrow supported wrapper format: one
    /// literal `exec <executable> acp ...` command. Comments, dynamic shell
    /// variables, and unrelated commands are ignored rather than guessed.
    static func extractExecutable(fromWrapperContents contents: String) -> URL? {
        guard let invocation = parseACPInvocation(from: contents) else { return nil }
        guard !invocation.executable.contains("$") else { return nil }
        return URL(fileURLWithPath: invocation.executable)
    }

    /// Extracts a flag from the same supported ACP invocation used to resolve
    /// the executable. Both `--flag value` and `--flag=value` are supported.
    static func extractFlagValue(named flag: String, fromWrapperContents contents: String) -> String? {
        guard let invocation = parseACPInvocation(from: contents) else { return nil }
        let arguments = invocation.arguments
        for (index, argument) in arguments.enumerated() {
            if argument == flag, arguments.indices.contains(index + 1) {
                let value = arguments[index + 1]
                return value.contains("$") ? nil : value
            }
            let prefix = "\(flag)="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                return value.isEmpty || value.contains("$") ? nil : value
            }
        }
        return nil
    }

    private static func parseACPInvocation(from contents: String) -> (executable: String, arguments: [String])? {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), line.hasPrefix("exec ") else { continue }
            guard let tokens = tokenizeShellLine(line), tokens.count >= 3, tokens[0] == "exec" else { continue }
            guard let acpIndex = tokens.firstIndex(of: "acp"), acpIndex == 2 else { continue }
            return (executable: tokens[1], arguments: Array(tokens.dropFirst(acpIndex + 1)))
        }
        return nil
    }

    /// Minimal shell-word tokenizer for the intentionally narrow generated
    /// wrapper format. It handles whitespace, single/double quotes, escapes,
    /// and comments, but deliberately does not evaluate variables.
    private static func tokenizeShellLine(_ line: String) -> [String]? {
        enum Quote { case none, single, double }
        var quote: Quote = .none
        var escaping = false
        var token = ""
        var tokens: [String] = []

        func appendToken() {
            if !token.isEmpty {
                tokens.append(token)
                token = ""
            }
        }

        for character in line {
            if escaping {
                token.append(character)
                escaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" { quote = .none } else { token.append(character) }
            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    escaping = true
                } else {
                    token.append(character)
                }
            case .none:
                if character == "#" && token.isEmpty {
                    appendToken()
                    return tokens
                } else if character == "'" {
                    quote = .single
                } else if character == "\"" {
                    quote = .double
                } else if character == "\\" {
                    escaping = true
                } else if character.isWhitespace {
                    appendToken()
                } else {
                    token.append(character)
                }
            }
        }

        guard quote == .none, !escaping else { return nil }
        appendToken()
        return tokens
    }

    // MARK: - Syntax validation

    /// Validates syntax with `/bin/zsh -n <path>` through the narrow process
    /// runner. Never executes the script's actual logic.
    private func checkZshSyntax(of wrapperURL: URL) -> Bool {
        let output = processRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-n", wrapperURL.path]
        )
        return output.exitCode == 0
    }
}
