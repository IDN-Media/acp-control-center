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

    /// Returns a structured provider observation that preserves the configured
    /// path from the plist. This is the single source of truth for provider
    /// state per refresh/rescan. Downstream consumers derive the legacy
    /// `DashboardSnapshot.wrapper` Result from this same observation.
    ///
    /// When the path exists but cannot be read (permissions, invalid UTF-8,
    /// is a directory, etc.), this classifies as `.wrapperInvalid` with a
    /// safe human-readable reason, not `.configuredPathMissing`.
    func readProviderObservation() -> ACPProviderObservation {
        let providerObservation = resolveProviderObservation()
        guard case .configuredPathMissing(let wrapperURL) = providerObservation else {
            return providerObservation
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: wrapperURL.path, isDirectory: &isDirectory)

        guard exists else {
            return .configuredPathMissing(configuredPath: wrapperURL)
        }

        // Exists but is a directory
        if isDirectory.boolValue {
            return .wrapperInvalid(
                wrapperURL: wrapperURL,
                reason: "Path is a directory, not a file"
            )
        }

        // Exists but not readable as UTF-8
        let contents: String
        do {
            contents = try String(contentsOf: wrapperURL, encoding: .utf8)
        } catch {
            return .wrapperInvalid(
                wrapperURL: wrapperURL,
                reason: "File exists but cannot be read: \(error.localizedDescription)"
            )
        }

        guard let cliExecutableURL = Self.extractExecutable(fromWrapperContents: contents) else {
            return .wrapperInvalid(
                wrapperURL: wrapperURL,
                reason: "Could not locate an executable invoked with 'acp' in wrapper"
            )
        }

        let modelID = Self.extractFlagValue(named: "--model", fromWrapperContents: contents)
        let effort = Self.extractFlagValue(named: "--effort", fromWrapperContents: contents)
        let isExecutable = fm.isExecutableFile(atPath: wrapperURL.path)
        let syntaxIsValid = checkZshSyntax(of: wrapperURL)

        let configuration = ACPWrapperConfiguration(
            wrapperURL: wrapperURL,
            cliExecutableURL: cliExecutableURL,
            modelID: modelID,
            effort: effort,
            isExecutable: isExecutable,
            syntaxIsValid: syntaxIsValid
        )

        if !isExecutable || !syntaxIsValid {
            return .wrapperInvalid(
                wrapperURL: wrapperURL,
                reason: !isExecutable ? "Wrapper is not executable" : "Wrapper has syntax errors"
            )
        }

        return .wrapperValid(configuration: configuration)
    }

    /// Derives the legacy `Result<ACPWrapperConfiguration, ReaderError>` from
    /// a provider observation. This ensures a single filesystem read is used
    /// per refresh cycle.
    static func wrapperResult(
        from observation: ACPProviderObservation
    ) -> Result<ACPWrapperConfiguration, ReaderError> {
        switch observation {
        case .noProvider:
            return .failure(.missing(reason: "No ACP provider configured"))
        case .configuredPathMissing(let configuredPath):
            return .failure(.missing(reason: "Wrapper file not found at \(configuredPath.path)"))
        case .wrapperInvalid(let wrapperURL, let reason):
            return .failure(.invalid(reason: "\(reason) at \(wrapperURL.path)"))
        case .wrapperValid(let configuration):
            return .success(configuration)
        }
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
    /// `agent` string as a file URL. Fail-closed: an unreadable ACP
    /// directory, an unreadable plist, a malformed plist, or a plist with an
    /// empty/missing agent are reported as `.wrapperInvalid` (with a
    /// structured reason) so the UI never misleads the user into believing
    /// there is no provider at all when configuration actually exists but
    /// cannot be inspected.
    private func resolveProviderObservation() -> ACPProviderObservation {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: acpDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            // Directory missing or unreadable. A missing directory is a
            // legitimate "no provider" (nothing configured yet); an
            // unreadable existing directory is a configuration we cannot
            // inspect and must not present as "no provider".
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: acpDirectory.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                return .wrapperInvalid(
                    wrapperURL: acpDirectory,
                    reason: "ACP provider directory exists but cannot be read: \(error.localizedDescription)"
                )
            }
            return .noProvider
        }

        let plistURLs = entries
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var candidates: [(isKiro: Bool, agentURL: URL)] = []
        for plistURL in plistURLs {
            let data: Data
            do {
                data = try Data(contentsOf: plistURL)
            } catch {
                return .wrapperInvalid(
                    wrapperURL: plistURL,
                    reason: "ACP provider plist exists but cannot be read: \(error.localizedDescription)"
                )
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return .wrapperInvalid(
                    wrapperURL: plistURL,
                    reason: "ACP provider plist is malformed"
                )
            }
            guard let agentPath = plist["agent"] as? String, !agentPath.isEmpty else {
                return .wrapperInvalid(
                    wrapperURL: plistURL,
                    reason: "ACP provider plist has no valid agent path"
                )
            }

            let name = (plist["name"] as? String)?.lowercased() ?? ""
            let isKiro = name.contains("kiro") || agentPath.lowercased().contains("kiro")
            candidates.append((isKiro: isKiro, agentURL: URL(fileURLWithPath: agentPath)))
        }

        // Prefer an explicitly Kiro-named ACP definition. If no provider can
        // be identified, deterministic filename ordering provides a stable
        // fallback rather than relying on filesystem enumeration order.
        return candidates.first(where: \.isKiro).map { .configuredPathMissing(configuredPath: $0.agentURL) }
            ?? candidates.first.map { .configuredPathMissing(configuredPath: $0.agentURL) }
            ?? .noProvider
    }

    // MARK: - Wrapper text parsing

    /// Validates the complete deterministic structure emitted by
    /// `ACPWrapperManager`. A marker plus one parseable `exec` line is not
    /// sufficient because arbitrary additional shell commands must not be
    /// treated as an ACC-owned wrapper.
    static func isGeneratedManagedWrapper(_ contents: String) -> Bool {
        var lines = contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lines.count == 7,
              lines[0] == "#!/bin/zsh",
              lines[1] == ACPWrapperManager.ownershipMarker,
              lines[2] == "# Managed by ACP Control Center. Review changes in the app before installing.",
              isLiteralAbsoluteExport(lines[3], key: "HOME", isPathList: false),
              isLiteralAbsoluteExport(lines[4], key: "PATH", isPathList: true),
              lines[5].isEmpty,
              lines[6].hasPrefix("exec "),
              let invocation = parseACPInvocation(from: contents),
              invocation.executable.hasPrefix("/"),
              !invocation.executable.contains("$"),
              areGeneratedArguments(invocation.arguments) else {
            return false
        }
        return true
    }

    private static func isLiteralAbsoluteExport(
        _ line: String,
        key: String,
        isPathList: Bool
    ) -> Bool {
        guard let tokens = tokenizeShellLine(line),
              tokens.count == 2,
              tokens[0] == "export" else {
            return false
        }
        let prefix = "\(key)="
        guard tokens[1].hasPrefix(prefix) else { return false }
        let value = String(tokens[1].dropFirst(prefix.count))
        guard !value.isEmpty, !value.contains("$") else { return false }
        if isPathList {
            return value.split(separator: ":", omittingEmptySubsequences: false)
                .allSatisfy { $0.hasPrefix("/") }
        }
        return value.hasPrefix("/")
    }

    private static func areGeneratedArguments(_ arguments: [String]) -> Bool {
        var index = 0
        if arguments.indices.contains(index), arguments[index] == "--model" {
            guard arguments.indices.contains(index + 1),
                  isValidGeneratedModelID(arguments[index + 1]) else {
                return false
            }
            index += 2
        }
        if arguments.indices.contains(index), arguments[index] == "--effort" {
            guard arguments.indices.contains(index + 1),
                  ACPWrapperEffort(rawValue: arguments[index + 1]) != nil else {
                return false
            }
            index += 2
        }
        return index == arguments.count
    }

    private static func isValidGeneratedModelID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._:/-")
        )
        return !value.isEmpty
            && value.count <= 200
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

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
