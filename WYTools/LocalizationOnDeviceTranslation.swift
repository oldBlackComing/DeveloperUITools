//
//  LocalizationOnDeviceTranslation.swift
//  WYTools
//

import Foundation
import SwiftUI
import Translation

// MARK: - Models

struct LocalizationMachineTranslationItem: Sendable {
    let locale: String
    let key: String
    let englishSource: String
}

enum LocalizationOnDeviceTranslationError: LocalizedError {
    case needsMacOS15
    case unsupportedLanguagePair(locale: String)
    case translationFailed(String)
    case emptyTranslationOutput

    var errorDescription: String? {
        switch self {
        case .needsMacOS15:
            return "本机翻译需要 macOS 15 或更高版本。"
        case .unsupportedLanguagePair(let locale):
            return "系统不支持从英文翻译到「\(locale)」（本机翻译语言列表中无此对）。"
        case .translationFailed(let message):
            return "本机翻译失败：\(message)"
        case .emptyTranslationOutput:
            return "本机翻译返回了空结果，请确认该语言包已下载完成。"
        }
    }
}

// MARK: - Locale → Apple Translation

enum LocalizationAppleLocaleMapping: Sendable {
    static func normalizeLocaleCode(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appleTargetIdentifier(forLprojLanguageCode code: String) -> String {
        let n = normalizeLocaleCode(code)
        let lower = n.lowercased()
        if lower.hasPrefix("zh-hans") { return "zh-Hans" }
        if lower.hasPrefix("zh-hant") { return "zh-Hant" }
        return n
    }

    static func englishSourceLanguage() -> Locale.Language {
        Locale.Language(identifier: "en")
    }

    static func targetLanguage(forLprojLanguageCode code: String) -> Locale.Language {
        Locale.Language(identifier: appleTargetIdentifier(forLprojLanguageCode: code))
    }
}

// MARK: - Availability

@available(macOS 15.0, *)
enum LocalizationOnDeviceTranslationSupport {
    static func lprojCodesNeedingDownload(fromEnglishToLprojCodes codes: [String]) async -> [String] {
        let availability = LanguageAvailability()
        let source = LocalizationAppleLocaleMapping.englishSourceLanguage()
        var need: [String] = []
        for code in Set(codes) {
            let target = LocalizationAppleLocaleMapping.targetLanguage(forLprojLanguageCode: code)
            let status = await availability.status(from: source, to: target)
            if status == .supported {
                need.append(code)
            }
        }
        return need.sorted()
    }

    static func firstUnsupportedLprojCode(fromEnglishToLprojCodes codes: [String]) async -> String? {
        let availability = LanguageAvailability()
        let source = LocalizationAppleLocaleMapping.englishSourceLanguage()
        for code in Set(codes) {
            let target = LocalizationAppleLocaleMapping.targetLanguage(forLprojLanguageCode: code)
            let status = await availability.status(from: source, to: target)
            if status == .unsupported {
                return code
            }
        }
        return nil
    }
}

// MARK: - SwiftUI translationTask 桥接

@MainActor
@Observable
final class OnDeviceTranslationCoordinator {
    fileprivate(set) var configuration: TranslationSession.Configuration?

    private var pendingAction: ((TranslationSession) async throws -> Void)?
    private var completion: CheckedContinuation<Void, Error>?

    func perform(
        configuration config: TranslationSession.Configuration,
        action: @escaping (TranslationSession) async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingAction = action
            completion = cont
            configuration = config
        }
    }

    fileprivate func deliver(session: TranslationSession) async {
        guard let action = pendingAction, let cont = completion else { return }
        pendingAction = nil
        completion = nil
        do {
            try await action(session)
            configuration = nil
            cont.resume()
        } catch {
            configuration = nil
            cont.resume(throwing: error)
        }
    }
}

@available(macOS 15.0, *)
struct OnDeviceTranslationRunner: View {
    @Bindable var coordinator: OnDeviceTranslationCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(coordinator.configuration) { session in
                await coordinator.deliver(session: session)
            }
    }
}

// MARK: - 翻译 + JSONL

@MainActor
enum LocalizationOnDeviceTranslationBatch {
    static func encodeJSONL(rows: [(locale: String, key: String, value: String)]) throws -> String {
        struct Row: Encodable {
            let locale: String
            let key: String
            let value: String
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        for r in rows {
            let data = try enc.encode(Row(locale: r.locale, key: r.key, value: r.value))
            guard let s = String(data: data, encoding: .utf8) else {
                throw LocalizationOnDeviceTranslationError.translationFailed("UTF-8 编码")
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    @available(macOS 15.0, *)
    private final class TranslationRowBox {
        var rows: [(locale: String, key: String, value: String)] = []
    }

    @available(macOS 15.0, *)
    private static func translateOneLocaleGroupReturningRows(
        locale: String,
        group: [LocalizationMachineTranslationItem],
        coordinator: OnDeviceTranslationCoordinator
    ) async throws -> [(locale: String, key: String, value: String)] {
        let sourceLang = LocalizationAppleLocaleMapping.englishSourceLanguage()
        let targetLang = LocalizationAppleLocaleMapping.targetLanguage(forLprojLanguageCode: locale)
        let config = TranslationSession.Configuration(source: sourceLang, target: targetLang)
        let sourceTexts = group.map {
            $0.englishSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.key : $0.englishSource
        }

        let box = TranslationRowBox()
        try await coordinator.perform(configuration: config) { session in
            let requests: [TranslationSession.Request] = sourceTexts.enumerated().map { idx, text in
                TranslationSession.Request(sourceText: text, clientIdentifier: "\(idx)")
            }
            let responses = try await session.translations(from: requests)
            var outs = Array(repeating: "", count: group.count)
            for response in responses {
                guard let id = response.clientIdentifier, let i = Int(id), i >= 0, i < outs.count else { continue }
                outs[i] = response.targetText
            }
            if outs.contains(where: { $0.isEmpty }) {
                throw LocalizationOnDeviceTranslationError.emptyTranslationOutput
            }
            for i in 0 ..< group.count {
                let it = group[i]
                box.rows.append((locale: it.locale, key: it.key, value: outs[i]))
            }
        }
        return box.rows
    }

    @available(macOS 15.0, *)
    static func translateAll(
        items: [LocalizationMachineTranslationItem],
        coordinator: OnDeviceTranslationCoordinator
    ) async throws -> [(locale: String, key: String, value: String)] {
        guard !items.isEmpty else { return [] }

        var byLocale: [String: [LocalizationMachineTranslationItem]] = [:]
        for it in items {
            byLocale[it.locale, default: []].append(it)
        }

        var results: [(locale: String, key: String, value: String)] = []
        results.reserveCapacity(items.count)

        for locale in byLocale.keys.sorted() {
            guard let group = byLocale[locale], !group.isEmpty else { continue }
            let part = try await translateOneLocaleGroupReturningRows(
                locale: locale,
                group: group,
                coordinator: coordinator
            )
            results.append(contentsOf: part)
        }

        return results
    }

    @available(macOS 15.0, *)
    static func prepareDownloads(forLprojLanguageCodes codes: [String], coordinator: OnDeviceTranslationCoordinator) async throws {
        let sourceLang = LocalizationAppleLocaleMapping.englishSourceLanguage()
        for code in codes {
            let targetLang = LocalizationAppleLocaleMapping.targetLanguage(forLprojLanguageCode: code)
            let config = TranslationSession.Configuration(source: sourceLang, target: targetLang)
            try await coordinator.perform(configuration: config) { session in
                try await session.prepareTranslation()
            }
        }
    }
}
