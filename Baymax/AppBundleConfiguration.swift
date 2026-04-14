//
//  AppBundleConfiguration.swift
//  Baymax
//

import Foundation

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }
        return nil
    }
}

public struct DotEnv {
    public static var env: [String: String] = [:]

    public static func load(path: String? = nil) {
        let resolvedPath: String
        if let path {
            resolvedPath = path
        } else {
            // Try multiple locations: next to the app bundle, in the project directory, then fallback
            let possiblePaths = [
                Bundle.main.bundlePath + "/../.env",
                "/Users/davejaga/Desktop/Startups/baymax/.env",
            ]
            resolvedPath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
                ?? "/Users/davejaga/Desktop/Startups/baymax/.env"
        }

        guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            print("⚠️ DotEnv: Could not find or read .env file at \(resolvedPath)")
            BaymaxDebugLog.log("DotEnv: FAILED to read .env at \(resolvedPath)")
            return
        }

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                var value = parts[1].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                env[key] = value
                setenv(key, value, 1)
            }
        }
        print("✅ DotEnv: Loaded \(env.keys.count) keys from \(resolvedPath)")
        BaymaxDebugLog.log("DotEnv: Loaded \(env.keys.count) keys — keys: \(env.keys.sorted().joined(separator: ", "))")
    }

    public static func get(_ key: String) -> String? {
        if env.isEmpty { load() }
        return env[key] ?? ProcessInfo.processInfo.environment[key]
    }
}

public class SupabaseAuthClient {
    public static let shared = SupabaseAuthClient()
    
    private var baseUrl: String {
        DotEnv.get("SUPABASE_URL")
            ?? ProcessInfo.processInfo.environment["SUPABASE_URL"]
            ?? ""
    }
    private var anonKey: String {
        DotEnv.get("SUPABASE_ANON_KEY")
            ?? ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
            ?? ""
    }
    
    private func makeRequest(path: String, method: String, body: [String: Any]? = nil, token: String? = nil) async throws -> Data {
        guard !baseUrl.isEmpty, !anonKey.isEmpty else {
            throw NSError(domain: "SupabaseAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Supabase is not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY in .env or the environment."])
        }
        guard let url = URL(string: "\(baseUrl)\(path)") else {
            throw NSError(domain: "SupabaseAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw NSError(domain: "SupabaseAuth", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorMsg)"])
        }
        return data
    }
    
    /// Fetches the authenticated user's ID and email from the Supabase
    /// `/auth/v1/user` endpoint. Used after OAuth to resolve the user
    /// when the callback URL only contains an access token.
    public func fetchUserInfo(accessToken: String) async throws -> (userId: String, email: String?)? {
        let data = try await makeRequest(
            path: "/auth/v1/user",
            method: "GET",
            token: accessToken
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["id"] as? String else {
            return nil
        }
        let email = json["email"] as? String
        return (userId: userId, email: email)
    }

    public func fetchTier(userId: String, accessToken: String) async throws -> String {
        let data = try await makeRequest(
            path: "/rest/v1/profiles?id=eq.\(userId)&select=tier",
            method: "GET",
            token: accessToken
        )
        
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = jsonArray.first,
              let tier = first["tier"] as? String else {
            return "free"
        }
        return tier
    }
    
    public func fetchUserEmail(accessToken: String) async throws -> String? {
        let data = try await makeRequest(
            path: "/auth/v1/user",
            method: "GET",
            token: accessToken
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }
}

enum BaymaxDebugLog {
    private static let logFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("baymac-debug.log")
    }()

    static func setup() {
        let header = "\n\n=== Baymac Launch \(Date()) ===\n"
        if let data = header.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print("🔍 \(message)")
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}
