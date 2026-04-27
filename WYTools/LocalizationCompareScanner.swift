//
//  LocalizationCompareScanner.swift
//  WYTools
//

import Foundation

// MARK: - Models

struct MissingLocalizationEntry: Sendable, Hashable, Identifiable {
    var id: String { key }
    let key: String
    let englishValue: String
}

struct LanguageMissingResult: Sendable, Identifiable {
    var id: String { languageCode }
    let languageCode: String
    let missingEntries: [MissingLocalizationEntry]
}

struct LocalizationCompareScanResult: Sendable {
    /// Human-readable note, e.g. "en, en-US" or "Base.lproj (no en*)"
    let englishReferenceDescription: String
    let englishKeyCount: Int
    /// When true, comparison uses only `.lproj` `.strings` keys as reference (String Catalog keys are ignored for ref / per-locale rows).
    let usedStringsFilesAsReference: Bool
    let languages: [LanguageMissingResult]
}

// MARK: - Scanner

enum LocalizationCompareScannerError: LocalizedError {
    case noEnglishReference
    case noStringsOrCatalogFound

    var errorDescription: String? {
        switch self {
        case .noEnglishReference:
            return "未找到英文参考：请在主工程中加入带 `.strings` 的 `en.lproj`（或 `en-US` / `en-GB`），或使用 `Base.lproj` / 含英文的 String Catalog（`.xcstrings`）。"
        case .noStringsOrCatalogFound:
            return "所选目录下未发现 `.lproj` 或 `.xcstrings`（或均在 `Pods/` 内已被忽略）。"
        }
    }
}

enum LocalizationCompareScanner {
    /// NFC so the same logical key matches across files (NFD vs NFC).
    nonisolated private static func normalizeEntryKey(_ key: String) -> String {
        key.precomposedStringWithCanonicalMapping
    }

    nonisolated private static func normalizeStringsDictionary(_ dict: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            out[normalizeEntryKey(k)] = v
        }
        return out
    }

    /// Loads a `.strings` plist; falls back when `NSDictionary(contentsOf:)` fails (e.g. UTF-16, encoding quirks).
    nonisolated private static func loadStringsPlist(from url: URL) throws -> [String: String]? {
        if let raw = NSDictionary(contentsOf: url) as? [String: String], !raw.isEmpty {
            return normalizeStringsDictionary(raw)
        }

        let data = try Data(contentsOf: url)
        if let parsed = tryParseStringsPlistData(data) {
            return parsed
        }

        let encodings: [String.Encoding] = [
            .utf8,
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf16,
        ]
        for enc in encodings {
            guard let text = String(data: data, encoding: enc),
                  let utf8 = text.data(using: .utf8),
                  let parsed = tryParseStringsPlistData(utf8)
            else { continue }
            return parsed
        }

        return nil
    }

    nonisolated private static func tryParseStringsPlistData(_ data: Data) -> [String: String]? {
        for startFormat in [
            PropertyListSerialization.PropertyListFormat.xml,
            .binary,
            .openStep,
        ] {
            var format = startFormat
            guard let any = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
                  let ns = any as? [String: Any],
                  !ns.isEmpty
            else { continue }

            var out: [String: String] = [:]
            out.reserveCapacity(ns.count)
            for (ks, v) in ns {
                guard let vs = v as? String else { continue }
                out[normalizeEntryKey(ks)] = vs
            }
            if !out.isEmpty { return out }
        }
        return nil
    }

    /// Merges dictionaries from all `.strings` inside a `.lproj` directory (recursive).
    nonisolated private static func mergedStringsDictionary(inLproj lproj: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: lproj,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var merged: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard fileURL.pathExtension.lowercased() == "strings" else { continue }
            guard let dict = try loadStringsPlist(from: fileURL) else { continue }
            merged.merge(dict) { _, new in new }
        }
        return merged
    }

    nonisolated private static func languageCode(fromLprojURL url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    nonisolated private static func normalizedLocaleToken(_ code: String) -> String {
        code.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    nonisolated private static func isEnglishLocaleCode(_ code: String) -> Bool {
        let n = normalizedLocaleToken(code)
        if n == "en" { return true }
        if n.hasPrefix("en-") { return true }
        if n == "english" { return true }
        return false
    }

    /// Only the main project: ignore everything under CocoaPods `Pods/`.
    nonisolated private static func isPathInsidePods(_ url: URL) -> Bool {
        url.path.range(of: "/Pods/", options: .caseInsensitive) != nil
    }

    /// Selecting a `.xcodeproj` / `.xcworkspace` bundle often misses `.lproj` next to it; include the parent folder.
    nonisolated private static func scanDirectoryRoots(primary: URL) -> [URL] {
        var roots = [primary.standardizedFileURL]
        let ext = primary.pathExtension.lowercased()
        if ext == "xcodeproj" || ext == "xcworkspace" {
            let parent = primary.deletingLastPathComponent().standardizedFileURL
            if parent != roots[0] {
                roots.append(parent)
            }
        }
        return roots
    }

    nonisolated private static func collectLprojRoots(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        var isRootDir = ObjCBool(false)
        guard fm.fileExists(atPath: root.path, isDirectory: &isRootDir), isRootDir.boolValue else { return [] }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var lprojs: [URL] = []
        for case let url as URL in enumerator {
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard url.pathExtension.lowercased() == "lproj" else { continue }
            guard !isPathInsidePods(url) else { continue }
            lprojs.append(url)
        }
        return lprojs
    }

    nonisolated private static func collectXCStringsFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard url.pathExtension.lowercased() == "xcstrings" else { continue }
            guard !isPathInsidePods(url) else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: String Catalog (.xcstrings)

    nonisolated private static func mergeFromXCStrings(
        file: URL,
        into perLocale: inout [String: [String: String]],
        englishValues: inout [String: String]
    ) throws {
        let data = try Data(contentsOf: file)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = obj as? [String: Any] else { return }
        let sourceLanguage = (root["sourceLanguage"] as? String).map(normalizedLocaleToken) ?? "en"
        guard let strings = root["strings"] as? [String: Any] else { return }

        for (entryKey, entryVal) in strings {
            let canonKey = normalizeEntryKey(entryKey)
            guard let entry = entryVal as? [String: Any] else { continue }
            let localizations = entry["localizations"] as? [String: [String: Any]]

            var englishForKey: String?
            if let locs = localizations {
                for (locCode, locDict) in locs {
                    let n = normalizedLocaleToken(locCode)
                    guard isEnglishLocaleCode(n) || n == sourceLanguage else { continue }
                    if let unit = locDict["stringUnit"] as? [String: Any],
                       let value = unit["value"] as? String,
                       !value.isEmpty
                    {
                        englishForKey = value
                        break
                    }
                }
            }
            if englishForKey == nil, let locs = localizations {
                if let unit = locs[sourceLanguage]?["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String,
                   !value.isEmpty
                {
                    englishForKey = value
                }
            }
            if let v = englishForKey {
                if englishValues[canonKey] == nil || englishValues[canonKey]?.isEmpty == true {
                    englishValues[canonKey] = v
                }
            }

            guard let locs = localizations else { continue }
            for (locCode, locDict) in locs {
                let code = normalizedDisplayLocaleCode(locCode)
                guard let unit = locDict["stringUnit"] as? [String: Any] else { continue }
                let state = (unit["state"] as? String)?.lowercased()
                let value = (unit["value"] as? String) ?? ""
                let present: Bool
                if state == "new" {
                    present = false
                } else {
                    present = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if present {
                    perLocale[code, default: [:]][canonKey] = value
                }
            }
        }

        // Do not add every catalog key to the English reference with empty values — that makes
        // `refKeys` huge vs `.lproj` strings and produces false "missing" rows for keys that only
        // exist in legacy `.strings` files.
    }

    /// Presents common BCP-47 casing (e.g. zh-hans → zh-Hans) for display only.
    nonisolated private static func normalizedDisplayLocaleCode(_ raw: String) -> String {
        if raw == "Base" { return "Base" }
        let parts = raw.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return raw }
        let head = parts[0].lowercased()
        let tail = parts.dropFirst().map { p in
            p.count <= 3 ? p.uppercased() : (p.prefix(1).uppercased() + p.dropFirst().lowercased())
        }
        return ([head] + tail).joined(separator: "-")
    }

    // MARK: Public

    nonisolated static func scan(projectRoot: URL) async throws -> LocalizationCompareScanResult {
        try await Task.detached(priority: .userInitiated) {
            try performScan(projectRoot: projectRoot)
        }.value
    }

    /// Builds the same scan state as `performScan` and prints why `entryKey` is or is not counted as missing per locale.
    nonisolated static func debugComparisonTrace(projectRoot: URL, entryKey: String) throws -> String {
        var lines: [String] = []
        func L(_ s: String) { lines.append(s) }

        let scanRoots = scanDirectoryRoots(primary: projectRoot)
        L("=== LocalizationCompare debug trace ===")
        L("Semantics: per locale, missing = keys in merged English .strings minus keys in that locale’s .strings (same NFC key).")
        L("Paths skipped: any path under /Pods/ (main project only).")
        L("projectRoot: \(projectRoot.path)")
        L("(1) scan roots (\(scanRoots.count)):")
        for r in scanRoots { L("    \(r.path)") }

        var seenLproj = Set<String>()
        var lprojs: [URL] = []
        for r in scanRoots {
            for u in try collectLprojRoots(under: r) where seenLproj.insert(u.path).inserted {
                lprojs.append(u)
            }
        }
        L("(2) unique .lproj count: \(lprojs.count)")
        let rootPath = projectRoot.standardizedFileURL.path
        let underRoot = lprojs.filter { $0.path.hasPrefix(rootPath) }
        L("    .lproj under selected root: \(underRoot.count) (of \(lprojs.count) total)")
        for u in underRoot.prefix(20) {
            L("    \(u.lastPathComponent) ← \(u.deletingLastPathComponent().lastPathComponent)")
        }
        if underRoot.count > 20 {
            L("    … (\(underRoot.count - 20) more under root)")
        }

        var perLocaleStrings: [String: [String: String]] = [:]
        for lproj in lprojs {
            let code = languageCode(fromLprojURL: lproj)
            let displayCode = normalizedDisplayLocaleCode(code)
            let dict = try mergedStringsDictionary(inLproj: lproj)
            guard !dict.isEmpty else { continue }
            perLocaleStrings[displayCode, default: [:]].merge(dict) { _, new in new }
        }
        L("(3) locale buckets: \(perLocaleStrings.keys.sorted().joined(separator: ", "))")

        var mergedEnglishLproj: [String: String] = [:]
        var englishCodesFound: [String] = []
        for (code, dict) in perLocaleStrings where isEnglishLocaleCode(code) {
            englishCodesFound.append(code)
            mergedEnglishLproj.merge(dict) { _, new in new }
        }
        if mergedEnglishLproj.isEmpty, let base = perLocaleStrings["Base"], !base.isEmpty {
            mergedEnglishLproj = base
            L("(4) English reference: Base.lproj (no en*)")
        } else {
            L("(4) English .lproj codes used: \(englishCodesFound.sorted().joined(separator: ", "))")
        }

        let canon = normalizeEntryKey(entryKey)
        L("(5) entry key (raw): \(entryKey.utf8.count) UTF-8 bytes")
        L("    entry key (NFC): \(canon.utf8.count) UTF-8 bytes → \"\(canon)\"")
        if entryKey != canon {
            L("    NOTE: raw != NFC (Unicode normalization changed the string).")
        }
        func utf8HexPrefix(_ s: String, _ n: Int) -> String {
            Array(s.utf8.prefix(n)).map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        L("    raw UTF-8 prefix: \(utf8HexPrefix(entryKey, 24))…")
        L("    NFC UTF-8 prefix: \(utf8HexPrefix(canon, 24))…")

        let inEnglishRef = mergedEnglishLproj[canon] != nil
        L("(6) key in mergedEnglishLproj (reference .strings): \(inEnglishRef ? "YES" : "NO")")
        if let v = mergedEnglishLproj[canon] {
            L("    value: \"\(v)\"")
        } else if let fuzzy = mergedEnglishLproj.keys.first(where: { $0.contains("10 consecutive") }) {
            L("    no exact NFC match; first key containing \"10 consecutive\": \"\(fuzzy)\"")
        }

        let useStringsFilesAsReference = !mergedEnglishLproj.isEmpty
        L("(7) useStringsFilesAsReference: \(useStringsFilesAsReference) (if false, String Catalog dominates refKeys)")

        let refKeys = Set(mergedEnglishLproj.keys)
        L("(8) refKeys.count (English .strings only when (7) is true): \(refKeys.count)")
        L("    refKeys.contains(NFC key): \(refKeys.contains(canon))")

        L("(9) per-locale .strings dict contains same NFC key?")
        for code in perLocaleStrings.keys.sorted() {
            let dict = perLocaleStrings[code]!
            let has = dict[canon] != nil
            L("    \(code): \(has ? "YES" : "NO")  (dict key count: \(dict.keys.count))")
        }

        L("(10) full `performScan` vs this NFC key (each locale row):")
        let scan = try performScan(projectRoot: projectRoot)
        L("    usedStringsFilesAsReference: \(scan.usedStringsFilesAsReference)")
        L("    englishKeyCount: \(scan.englishKeyCount)")
        for row in scan.languages.sorted(by: { $0.languageCode < $1.languageCode }) {
            let missingThis = row.missingEntries.contains { $0.key == canon }
            L("    \(row.languageCode): total_missing=\(row.missingEntries.count)  this_key_as_missing=\(missingThis)")
        }

        return lines.joined(separator: "\n")
    }

    nonisolated private static func performScan(projectRoot: URL) throws -> LocalizationCompareScanResult {
        let scanRoots = scanDirectoryRoots(primary: projectRoot)
        var seenLproj = Set<String>()
        var lprojs: [URL] = []
        for r in scanRoots {
            for u in try collectLprojRoots(under: r) where seenLproj.insert(u.path).inserted {
                lprojs.append(u)
            }
        }

        var seenXC = Set<String>()
        var xcFiles: [URL] = []
        for r in scanRoots {
            for u in try collectXCStringsFiles(under: r) where seenXC.insert(u.path).inserted {
                xcFiles.append(u)
            }
        }

        var perLocaleStrings: [String: [String: String]] = [:]

        for lproj in lprojs {
            let code = languageCode(fromLprojURL: lproj)
            let displayCode = normalizedDisplayLocaleCode(code)
            let dict = try mergedStringsDictionary(inLproj: lproj)
            guard !dict.isEmpty else { continue }
            perLocaleStrings[displayCode, default: [:]].merge(dict) { _, new in new }
        }

        var englishFromCatalog: [String: String] = [:]
        var catalogLocaleMaps: [String: [String: String]] = [:]
        for f in xcFiles {
            try mergeFromXCStrings(file: f, into: &catalogLocaleMaps, englishValues: &englishFromCatalog)
        }

        if lprojs.isEmpty, xcFiles.isEmpty {
            throw LocalizationCompareScannerError.noStringsOrCatalogFound
        }

        var mergedEnglishLproj: [String: String] = [:]
        var englishCodesFound: [String] = []

        for (code, dict) in perLocaleStrings where isEnglishLocaleCode(code) {
            englishCodesFound.append(code)
            mergedEnglishLproj.merge(dict) { _, new in new }
        }

        var usedBaseAsEnglishFallback = false
        if mergedEnglishLproj.isEmpty, let base = perLocaleStrings["Base"], !base.isEmpty {
            mergedEnglishLproj = base
            usedBaseAsEnglishFallback = true
        }

        var mergedEnglishFull: [String: String] = mergedEnglishLproj
        mergedEnglishFull.merge(englishFromCatalog) { old, new in
            old.isEmpty ? new : old
        }

        for (code, dict) in catalogLocaleMaps where isEnglishLocaleCode(code) {
            if !englishCodesFound.contains(where: { normalizedLocaleToken($0) == normalizedLocaleToken(code) }) {
                englishCodesFound.append(code)
            }
            mergedEnglishFull.merge(dict) { _, new in new }
        }

        if mergedEnglishFull.isEmpty {
            throw LocalizationCompareScannerError.noEnglishReference
        }

        /// When the app has real `en` / `Base` `.strings`, use **only** those keys as the reference. Otherwise SPM / SDK
        /// `.xcstrings` (dozens of locales, hundreds of keys) dominate and every `.lproj` looks wrongly incomplete.
        let useStringsFilesAsReference = !mergedEnglishLproj.isEmpty

        let refKeys: Set<String>
        var mergedEnglishDisplay: [String: String]

        if useStringsFilesAsReference {
            refKeys = Set(mergedEnglishLproj.keys)
            mergedEnglishDisplay = mergedEnglishLproj
            var catalogEnglishForFill: [String: String] = [:]
            for (code, dict) in catalogLocaleMaps where isEnglishLocaleCode(code) {
                catalogEnglishForFill.merge(dict) { _, new in new }
            }
            for k in refKeys {
                guard (mergedEnglishDisplay[k] ?? "").isEmpty else { continue }
                if let v = englishFromCatalog[k], !v.isEmpty {
                    mergedEnglishDisplay[k] = v
                } else if let v = catalogEnglishForFill[k], !v.isEmpty {
                    mergedEnglishDisplay[k] = v
                }
            }
        } else {
            refKeys = Set(mergedEnglishFull.keys)
            mergedEnglishDisplay = mergedEnglishFull
        }

        let englishDescription: String
        if usedBaseAsEnglishFallback {
            englishDescription = "Base.lproj (no en*.lproj)"
        } else if useStringsFilesAsReference {
            let unique = Array(Set(englishCodesFound)).sorted()
            englishDescription = unique.isEmpty ? "en (.strings)" : "\(unique.joined(separator: ", ")) (.strings)"
        } else {
            let unique = Array(Set(englishCodesFound)).sorted()
            englishDescription = unique.isEmpty ? "en (String Catalog)" : unique.joined(separator: ", ")
        }

        let englishNorms = Set(englishCodesFound.map { normalizedLocaleToken($0) })

        var languageRows: [LanguageMissingResult] = []

        if useStringsFilesAsReference {
            for (code, dict) in perLocaleStrings.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                let norm = normalizedLocaleToken(code)
                if isEnglishLocaleCode(code) { continue }
                if code == "Base", usedBaseAsEnglishFallback { continue }
                if code == "Base" { continue }
                if englishNorms.contains(norm) { continue }

                let missingKeys = refKeys.subtracting(Set(dict.keys)).sorted()
                let entries = missingKeys.map { k in
                    MissingLocalizationEntry(key: k, englishValue: mergedEnglishDisplay[k] ?? "")
                }
                languageRows.append(LanguageMissingResult(languageCode: code, missingEntries: entries))
            }
        } else {
            var perLocaleUnion: [String: [String: String]] = [:]
            for (code, dict) in perLocaleStrings {
                perLocaleUnion[code, default: [:]].merge(dict) { _, new in new }
            }
            for (code, dict) in catalogLocaleMaps {
                perLocaleUnion[code, default: [:]].merge(dict) { _, new in new }
            }

            for (code, dict) in perLocaleUnion.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                let norm = normalizedLocaleToken(code)
                if isEnglishLocaleCode(code) { continue }
                if code == "Base", usedBaseAsEnglishFallback { continue }
                if code == "Base" { continue }
                if englishNorms.contains(norm) { continue }

                let missingKeys = refKeys.subtracting(Set(dict.keys)).sorted()
                let entries = missingKeys.map { k in
                    MissingLocalizationEntry(key: k, englishValue: mergedEnglishDisplay[k] ?? "")
                }
                languageRows.append(LanguageMissingResult(languageCode: code, missingEntries: entries))
            }
        }

        return LocalizationCompareScanResult(
            englishReferenceDescription: englishDescription,
            englishKeyCount: refKeys.count,
            usedStringsFilesAsReference: useStringsFilesAsReference,
            languages: languageRows
        )
    }

    // MARK: - Paths for Cursor / append

    /// 与扫描相同的规则：扫描根目录下所有 `.lproj`（排除 `Pods/`），去重。
    nonisolated static func includedLprojRoots(projectRoot: URL) throws -> [URL] {
        let scanRoots = scanDirectoryRoots(primary: projectRoot)
        var seen = Set<String>()
        var lprojs: [URL] = []
        for r in scanRoots {
            for u in try collectLprojRoots(under: r) where seen.insert(u.path).inserted {
                lprojs.append(u)
            }
        }
        return lprojs
    }

    /// `ar.lproj` → 与扫描一致的展示用语言码（如 `zh-Hans`）。
    nonisolated static func displayLocaleCode(forLproj lproj: URL) -> String {
        let code = languageCode(fromLprojURL: lproj)
        return normalizedDisplayLocaleCode(code)
    }
}
