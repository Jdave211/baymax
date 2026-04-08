import Foundation

enum DotEnv {
    private static var cached: [String: String]?

    static func load() -> [String: String] {
        if let cached { return cached }

        for url in candidateURLs() {
            if FileManager.default.fileExists(atPath: url.path),
               let contents = try? String(contentsOf: url, encoding: .utf8) {
                let result = parse(contents)
                print("[Baymax] Loaded .env from \(url.path) (\(result.count) keys)")
                cached = result
                return result
            }
        }

        print("[Baymax] WARNING: .env not found in any candidate path")
        cached = [:]
        return [:]
    }

    static func value(for key: String) -> String? {
        load()[key]
    }

    private static func candidateURLs() -> [URL] {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let bundleURL = Bundle.main.bundleURL

        // Use compile-time source path to locate project root
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()  // Utilities/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // project root

        return [
            // Best bet: derive from source file at compile time
            projectRoot.appendingPathComponent(".env"),
            // Hardcoded project path as fallback
            URL(fileURLWithPath: "/Users/davejaga/Desktop/Startups/baymax/.env"),
            // CWD (works if launched from project dir)
            cwd.appendingPathComponent(".env"),
            // Bundle-relative (Xcode DerivedData layout)
            bundleURL.deletingLastPathComponent().appendingPathComponent(".env"),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"),
        ]
    }

    private static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)

            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            if !key.isEmpty {
                result[key] = value
            }
        }

        return result
    }
}
