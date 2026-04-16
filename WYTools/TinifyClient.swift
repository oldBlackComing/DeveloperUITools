//
//  TinifyClient.swift
//  WYTools
//

import Foundation

enum TinifyClientError: LocalizedError {
    case missingOutputURL
    case noAPIKeys
    case allKeysExhausted
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingOutputURL:
            return "未收到压缩结果地址，请检查网络或 API Key。"
        case .noAPIKeys:
            return "未配置 API Key"
        case .allKeysExhausted:
            return "ALL_KEYS_EXHAUSTED"
        case .emptyResponse:
            return "空响应"
        }
    }
}

enum TinifyClient {
    private static let shrinkURL = URL(string: "https://api.tinify.com/shrink")!

    private static func basicAuthHeader(apiKey: String) -> String {
        let raw = Data("api:\(apiKey)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    private static func isQuotaOrRateLimit(status: Int, message: String) -> Bool {
        if status == 429 || status == 402 { return true }
        let m = message.lowercased()
        let hints = [
            "too many requests",
            "monthly limit",
            "compression count",
            "limit exceeded",
            "too many compressions",
            "count exceeded",
            "usage limit",
            "quota",
            "exceeded your",
            "upgrade your",
            "pay for",
            "payment required",
            "rate limit",
        ]
        return hints.contains { m.contains($0) }
    }

    private static func parseErrorMessage(data: Data?, response: HTTPURLResponse?) -> String {
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? String { return e }
            if let m = obj["message"] as? String { return m }
        }
        if let s = data.flatMap({ String(data: $0, encoding: .utf8) }), !s.isEmpty { return s }
        if let r = response {
            return HTTPURLResponse.localizedString(forStatusCode: r.statusCode)
        }
        return "未知错误"
    }

    static func parseAPIKeys(from text: String) -> [String] {
        let parts = text
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var out: [String] = []
        for p in parts where !seen.contains(p) {
            seen.insert(p)
            out.append(p)
        }
        return out
    }

    /// 与网页版逻辑一致：多 Key 轮换，遇额度/限流自动换 Key。
    static func compress(
        imageData: Data,
        filename: String,
        apiKeys: [String],
        urlSession: URLSession = .shared
    ) async throws -> (inBytes: Int, outBytes: Int, outputData: Data, suggestedDownloadName: String) {
        if apiKeys.isEmpty { throw TinifyClientError.noAPIKeys }
        var exhausted = Set<String>()

        while true {
            guard let key = apiKeys.first(where: { !exhausted.contains($0) }) else {
                throw TinifyClientError.allKeysExhausted
            }

            do {
                return try await shrinkOnce(
                    imageData: imageData,
                    filename: filename,
                    apiKey: key,
                    urlSession: urlSession
                )
            } catch {
                if let err = error as? TinifyHTTPError {
                    if isQuotaOrRateLimit(status: err.statusCode, message: err.message) {
                        exhausted.insert(key)
                        continue
                    }
                }
                throw error
            }
        }
    }

    private struct TinifyHTTPError: LocalizedError {
        let statusCode: Int
        let message: String
        var errorDescription: String? { message }
    }

    private static func shrinkOnce(
        imageData: Data,
        filename: String,
        apiKey: String,
        urlSession: URLSession
    ) async throws -> (inBytes: Int, outBytes: Int, outputData: Data, suggestedDownloadName: String) {
        var req = URLRequest(url: shrinkURL)
        req.httpMethod = "POST"
        req.setValue(basicAuthHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = imageData

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if !(200...299).contains(http.statusCode) {
            let msg = parseErrorMessage(data: data, response: http)
            throw TinifyHTTPError(statusCode: http.statusCode, message: msg)
        }

        guard let location = http.value(forHTTPHeaderField: "Location"),
              let outputURL = URL(string: location)
        else {
            throw TinifyClientError.missingOutputURL
        }

        var dl = URLRequest(url: outputURL)
        dl.setValue(basicAuthHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")

        let (outData, outResp) = try await urlSession.data(for: dl)
        guard let outHttp = outResp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200...299).contains(outHttp.statusCode) {
            let msg = parseErrorMessage(data: outData, response: outHttp)
            throw TinifyHTTPError(statusCode: outHttp.statusCode, message: msg)
        }

        let inBytes = imageData.count
        let outBytes = outData.count

        var ext = (filename as NSString).pathExtension.lowercased()
        let allowed = ["jpg", "jpeg", "png", "webp", "avif"]
        if !allowed.contains(ext) {
            let ct = outHttp.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if ct.contains("jpeg") { ext = "jpg" }
            else if ct.contains("png") { ext = "png" }
            else if ct.contains("webp") { ext = "webp" }
            else if ct.contains("avif") { ext = "avif" }
            else { ext = "bin" }
        }
        let base = (filename as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "image" : base
        let downloadName = "\(safeBase)-tiny.\(ext)"

        return (inBytes, outBytes, outData, downloadName)
    }
}
