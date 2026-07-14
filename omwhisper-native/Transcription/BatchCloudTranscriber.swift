//
//  BatchCloudTranscriber.swift
//  OmWhisper
//
//  Shared "batch" cloud transcription for the on-release providers (ElevenLabs
//  Scribe / OpenAI / Groq): accumulate the whole mic stream → 16 kHz mono Int16
//  → a WAV container → multipart POST → parse the `text` field → one .final.
//  Same transcribe-on-release shape the Whisper engine uses. The three providers
//  differ only by a small Config (URL / auth header / model field / response key),
//  so one code path covers all of them. API shapes verified against live docs
//  2026-07-12 — see the spec.
//

import Foundation

nonisolated struct BatchCloudTranscriber {

    enum BatchError: Error, LocalizedError {
        case audioFormat
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .audioFormat: "Couldn't prepare audio for the cloud provider."
            case .http(let code): "Cloud provider returned status \(code)."
            }
        }
    }

    /// The only per-provider differences among the batch providers.
    struct Config: Sendable {
        let url: URL
        let authHeader: String   // "Authorization" (OpenAI/Groq) or "xi-api-key" (ElevenLabs)
        let authBearer: Bool     // true → "Bearer <key>"; false → raw key
        let modelField: String   // "model" (OpenAI/Groq) or "model_id" (ElevenLabs)
        let model: String
        let languageField: String?  // "language" / "language_code" / nil
        let responseKey: String  // "text" / "transcript"
        var extraFields: [String: String] = [:]  // provider-specific form fields (e.g. Sarvam's mode=translate)

        func authValue(_ key: String) -> String { authBearer ? "Bearer \(key)" : key }
    }

    static func openAI() -> Config {
        Config(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
               authHeader: "Authorization", authBearer: true,
               modelField: "model", model: "gpt-4o-transcribe",
               languageField: "language", responseKey: "text")
    }
    static func groq() -> Config {
        Config(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
               authHeader: "Authorization", authBearer: true,
               modelField: "model", model: "whisper-large-v3-turbo",
               languageField: "language", responseKey: "text")
    }
    static func elevenLabs() -> Config {
        Config(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
               authHeader: "xi-api-key", authBearer: false,
               modelField: "model_id", model: "scribe_v1",
               languageField: "language_code", responseKey: "text")
    }
    /// Sarvam Saaras speech-to-text in translate mode (Indic speech → English).
    /// API shape confirmed against a live key 2026-07-14 (response field `transcript`).
    static func sarvam() -> Config {
        Config(url: URL(string: "https://api.sarvam.ai/speech-to-text")!,
               authHeader: "api-subscription-key", authBearer: false,
               modelField: "model", model: "saaras:v3",
               languageField: "language_code", responseKey: "transcript",
               extraFields: ["mode": "translate"])
    }

    /// nil for the streaming providers (they don't use this path).
    static func config(for provider: CloudProviderKind) -> Config? {
        switch provider {
        case .openAI: openAI()
        case .groq: groq()
        case .elevenLabs: elevenLabs()
        case .assemblyAI, .deepgram: nil
        }
    }

    // MARK: Pure helpers (unit-tested, no network)

    /// 16-bit mono PCM samples → a minimal WAV container (44-byte header + payload).
    nonisolated static func pcmToWav(int16 samples: [Int16], sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(2); u16(16)
        str("data"); u32(UInt32(dataSize))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    nonisolated static func multipartBody(wav: Data, config: Config, language: String?, boundary: String) -> Data {
        var d = Data()
        func field(_ name: String, _ value: String) {
            d.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field(config.modelField, config.model)
        for (name, value) in config.extraFields.sorted(by: { $0.key < $1.key }) { field(name, value) }
        if let lf = config.languageField, let language, language != "auto" { field(lf, language) }
        d.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        d.append(wav)
        d.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return d
    }

    nonisolated static func parseText(_ data: Data, key: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Effectful

    /// POSTs the accumulated 16 kHz mono Int16 samples (CloudEngine owns the audio
    /// loop and hands them here) as a WAV multipart upload; returns the transcript.
    static func post(
        samples: [Int16], config: Config, apiKey: String, language: String?
    ) async throws -> String {
        guard !samples.isEmpty else { return "" }

        let wav = pcmToWav(int16: samples, sampleRate: 16000)
        let boundary = "omwhisper-\(UUID().uuidString)"
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue(config.authValue(apiKey), forHTTPHeaderField: config.authHeader)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(wav: wav, config: config, language: language, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BatchError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return parseText(data, key: config.responseKey) ?? ""
    }

    /// POSTs ~0.1s of silence to validate the key (auth). 401/403 → bad key; any
    /// other status means auth was accepted (a non-auth error like empty-audio 400
    /// still proves the key works). Backs Settings' Test Connection.
    static func testConnection(config: Config, apiKey: String) async -> String? {
        let wav = pcmToWav(int16: [Int16](repeating: 0, count: 1600), sampleRate: 16000)
        let boundary = "omwhisper-\(UUID().uuidString)"
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue(config.authValue(apiKey), forHTTPHeaderField: config.authHeader)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(wav: wav, config: config, language: nil, boundary: boundary)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return "Couldn't reach \(config.url.host ?? "the service")."
        }
        switch http.statusCode {
        case 401, 403: return "Invalid API key."
        default: return nil
        }
    }
}
