import Foundation

/// Local API smoke tests — keys must come from the environment only (never commit secrets).
/// Example:
///   ANTHROPIC_API_KEY=... ELEVENLABS_API_KEY=... swift test_apis.swift

let semaphore = DispatchSemaphore(value: 0)

guard let anthropicKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !anthropicKey.isEmpty else {
    fputs("Set ANTHROPIC_API_KEY in the environment.\n", stderr)
    exit(1)
}
guard let elevenLabsKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !elevenLabsKey.isEmpty else {
    fputs("Set ELEVENLABS_API_KEY in the environment.\n", stderr)
    exit(1)
}

// Test Anthropic
var antReq = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
antReq.httpMethod = "POST"
antReq.setValue(anthropicKey, forHTTPHeaderField: "x-api-key")
antReq.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
antReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

let antBody: [String: Any] = [
    "model": "claude-3-5-sonnet-20241022",
    "max_tokens": 10,
    "messages": [["role": "user", "content": "hi"]]
]
antReq.httpBody = try! JSONSerialization.data(withJSONObject: antBody)

URLSession.shared.dataTask(with: antReq) { data, response, error in
    if let data = data, let str = String(data: data, encoding: .utf8) {
        print("Anthropic:", (response as? HTTPURLResponse)?.statusCode ?? -1, str)
    }
    semaphore.signal()
}.resume()

semaphore.wait()

// Test ElevenLabs
var elReq = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/fI7zKH1sH6G6Q8W6fnyw")!)
elReq.httpMethod = "POST"
elReq.setValue(elevenLabsKey, forHTTPHeaderField: "xi-api-key")
elReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

let elBody: [String: Any] = [
    "text": "hi",
    "model_id": "eleven_flash_v2_5"
]
elReq.httpBody = try! JSONSerialization.data(withJSONObject: elBody)

URLSession.shared.dataTask(with: elReq) { data, response, error in
    if let data = data, let str = String(data: data, encoding: .utf8) {
        print("ElevenLabs:", (response as? HTTPURLResponse)?.statusCode ?? -1, str)
    }
    semaphore.signal()
}.resume()

semaphore.wait()
