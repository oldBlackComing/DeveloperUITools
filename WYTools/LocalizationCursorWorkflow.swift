//
//  LocalizationCursorWorkflow.swift
//  WYTools
//

import AppKit
import Foundation

/// 生成 Cursor 提示词、尝试拉起 Cursor/CLI、解析译文并写入 `.strings`。
@MainActor
enum LocalizationCursorWorkflow {

    /// 拉起 Cursor 后的结果（用于界面引导）。
    struct CursorPromptLaunchResult: Sendable {
        let summary: String
        let tempFileURL: URL?
    }

    /// 可粘贴到 Cursor 聊天里的一句口令（也在生成的 `.md` 里重复出现）。
    static let cursorChatOneLiner =
        "请阅读本文件中的「待翻译条目」与「输出要求」，只输出 JSON Lines（每行一个 JSON），不要 Markdown 代码围栏，不要任何解释或前后缀。"

    // MARK: Prompt

    /// 生成给 Cursor 的 Markdown 提示词（含 JSONL 输出约定）。
    static func buildTranslationPrompt(
        projectRootPath: String,
        scanResult: LocalizationCompareScanResult,
        selected: Set<LocalizationMissingEntryID>
    ) -> String {
        var lines: [String] = []
        lines.append("# WYTools 本地化翻译任务")
        lines.append("")
        lines.append("## 在 Cursor 里怎么做（按顺序）")
        lines.append("")
        lines.append("1. 按 **Cmd+L** 打开聊天，或打开 **Composer**。")
        lines.append("2. 在输入框输入 **@** 并选择 **本 Markdown 文件**（把整份说明交给模型）；若不会用 @，也可全选本文件内容粘贴到聊天。")
        lines.append("3. **再粘贴下面这一整行**作为你的发送内容（或在其后回车发送）：")
        lines.append("")
        lines.append("```")
        lines.append(cursorChatOneLiner)
        lines.append("```")
        lines.append("")
        lines.append("4. 等模型生成结束后，**只复制回复里的 JSON 行**（以 `{` 开头、`}` 结尾、一行一条），不要复制 markdown 围栏或说明文字。")
        lines.append("5. 回到 **WYTools**，在自动弹出的窗口里点 **「从剪贴板读取并写入工程」**，或使用主界面 **「第 2 步：从剪贴板写入工程」**。")
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("工程根路径：`\(projectRootPath)`")
        lines.append("")
        lines.append("请将下列 **已勾选** 的缺失项翻译成对应语言的 **自然、符合 iOS 习惯的译文**。")
        lines.append("")
        lines.append("## 输出要求（必须严格遵守）")
        lines.append("")
        lines.append("1. **只输出 JSON Lines**：每一行一个 JSON 对象，不要 Markdown 代码围栏，不要任何前言或结语。")
        lines.append("2. 每行格式：`{\"locale\":\"语言码\",\"key\":\"原文 key\",\"value\":\"译文\"}`")
        lines.append("   - `locale` 必须与下表分组标题中的语言码一致（`locale` 与工程内语言码会按**忽略大小写**匹配）。")
        lines.append("   - `key` 必须与下表完全一致（含空格与符号）。")
        lines.append("   - `value` 为译文；字符串中的 `\"` 与 `\\` 必须写成 JSON 转义。")
        lines.append("3. 不要省略任何一行；不要合并多行。")
        lines.append("")
        lines.append("## 待翻译条目（按语言）")
        lines.append("")

        let byLocale = Dictionary(grouping: selected) { $0.languageCode }
        for locale in byLocale.keys.sorted() {
            guard let ids = byLocale[locale], !ids.isEmpty else { continue }
            lines.append("### locale = `\(locale)`")
            lines.append("")
            guard let row = scanResult.languages.first(where: { $0.languageCode == locale }) else { continue }
            var enByKey: [String: String] = [:]
            for e in row.missingEntries { enByKey[e.key] = e.englishValue }
            for id in Array(ids).sorted(by: { $0.key < $1.key }) {
                let en = enByKey[id.key] ?? ""
                lines.append("- key: `\(id.key)`")
                lines.append("  - English（参考）: \(en.isEmpty ? "（空）" : en)")
            }
            lines.append("")
        }

        lines.append("## 输出示例（格式示意，勿照抄内容）")
        lines.append("")
        lines.append(#"{"locale":"zh-Hans","key":"Hello","value":"你好"}"#)
        return lines.joined(separator: "\n")
    }

    // MARK: Cursor / open

    /// 复制提示词到剪贴板；尝试用 Cursor CLI 或 `open -a Cursor` 打开提示文件。
    static func copyPromptAndOpenInCursor(prompt: String) -> CursorPromptLaunchResult {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt, forType: .string)

        let name = "WYTools_localization_prompt_\(Int(Date().timeIntervalSince1970)).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try prompt.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return CursorPromptLaunchResult(
                summary: "已复制提示词到剪贴板。写入临时文件失败：\(error.localizedDescription)。请在 Cursor 中新建文件并粘贴；随后回到本应用按引导写入工程。",
                tempFileURL: nil
            )
        }

        let cliPaths = [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cursor").path,
        ]

        for cli in cliPaths where FileManager.default.isExecutableFile(atPath: cli) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [url.path]
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    return CursorPromptLaunchResult(
                        summary: "已通过 `cursor` 打开提示文件 `\(name)`，且全文已在剪贴板。请按本窗口里的步骤在 Cursor 中发送口令并复制 JSONL。",
                        tempFileURL: url
                    )
                }
            } catch {
                continue
            }
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Cursor", url.path]
        do {
            try open.run()
            open.waitUntilExit()
            if open.terminationStatus == 0 {
                return CursorPromptLaunchResult(
                    summary: "已用「Cursor」打开 `\(name)`，且全文已在剪贴板。请按本窗口里的步骤操作。",
                    tempFileURL: url
                )
            }
        } catch {
            // fall through
        }

        return CursorPromptLaunchResult(
            summary: "提示词已在剪贴板；未能自动打开 Cursor。请手动打开 Cursor，用「文件 → 打开」打开下方路径中的文件，或新建对话后粘贴剪贴板。",
            tempFileURL: url
        )
    }

    // MARK: Parse + append

    struct AppendReport: Sendable {
        let appendedLineCount: Int
        let skippedLineCount: Int
        let messages: [String]
    }

    /// 解析 JSONL，将 `locale`+`key` 在 `selected` 中的条目追加到对应语言的主 `Localizable.strings` 末尾。
    static func applyPastedJSONL(
        text: String,
        projectRoot: URL,
        scanResult: LocalizationCompareScanResult,
        selected: Set<LocalizationMissingEntryID>
    ) throws -> AppendReport {
        var pairs: [String: [(key: String, value: String)]] = [:]
        var skipped = 0
        var parseNotes: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("//") { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loc = obj["locale"] as? String,
                  let key = obj["key"] as? String,
                  let value = obj["value"] as? String
            else {
                skipped += 1
                continue
            }

            let keyN = key.precomposedStringWithCanonicalMapping
            guard let match = selected.first(where: {
                $0.key == keyN && $0.languageCode.caseInsensitiveCompare(loc) == .orderedSame
            }) else {
                skipped += 1
                continue
            }

            pairs[match.languageCode, default: []].append((key: keyN, value: value))
        }

        if pairs.isEmpty {
            throw AppendError.noValidLines
        }

        let lprojs = try LocalizationCompareScanner.includedLprojRoots(projectRoot: projectRoot)
        var totalAppended = 0
        var messages: [String] = []

        for (locale, items) in pairs.sorted(by: { $0.key < $1.key }) {
            guard let fileURL = try pickPrimaryLocalizableStrings(localeDisplayCode: locale, lprojRoots: lprojs, projectRoot: projectRoot) else {
                parseNotes.append("未找到语言 `\(locale)` 的 Localizable.strings，已跳过 \(items.count) 条。")
                skipped += items.count
                continue
            }

            let existing = (NSDictionary(contentsOf: fileURL) as? [String: String]) ?? [:]
            var toWrite: [(key: String, value: String)] = []
            for item in items {
                if existing[item.key] != nil {
                    skipped += 1
                    continue
                }
                toWrite.append((key: item.key, value: item.value))
            }

            if toWrite.isEmpty {
                messages.append("`\(locale)`：文件已含这些 key，未追加。")
                continue
            }

            let block = toWrite.map { escapeStringsLine(key: $0.key, value: $0.value) }.joined(separator: "\n")
            try appendBlockToStringsFile(fileURL: fileURL, block: block)
            totalAppended += toWrite.count
            messages.append("`\(locale)`：已向 `\(fileURL.path)` 末尾追加 \(toWrite.count) 条。")
        }

        return AppendReport(appendedLineCount: totalAppended, skippedLineCount: skipped, messages: messages + parseNotes)
    }

    enum AppendError: LocalizedError {
        case noValidLines

        var errorDescription: String? {
            switch self {
            case .noValidLines:
                return "没有解析到有效的 JSONL 行（需为 {\"locale\":\"…\",\"key\":\"…\",\"value\":\"…\"}，且 key 必须属于当前勾选且与 locale 一致）。"
            }
        }
    }

    private static func escapeStringsLine(key: String, value: String) -> String {
        let ek = escapeForStrings(key)
        let ev = escapeForStrings(value)
        return "\"\(ek)\" = \"\(ev)\";"
    }

    private static func escapeForStrings(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func readTextFile(url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try String(contentsOf: url, encoding: .utf16)
    }

    private static func appendBlockToStringsFile(fileURL: URL, block: String) throws {
        var body = try readTextFile(url: fileURL)
        if !body.hasSuffix("\n") { body.append("\n") }
        body.append("\n/* Appended by WYTools — localization */\n")
        body.append(block)
        body.append("\n")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 优先：`根名/根名/locale.lproj/Localizable.strings`；否则取该语言下路径最短的 `Localizable.strings`。
    private static func pickPrimaryLocalizableStrings(
        localeDisplayCode: String,
        lprojRoots: [URL],
        projectRoot: URL
    ) throws -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for lproj in lprojRoots {
            let code = LocalizationCompareScanner.displayLocaleCode(forLproj: lproj)
            guard code == localeDisplayCode else { continue }
            guard let subs = try? fm.contentsOfDirectory(at: lproj, includingPropertiesForKeys: nil) else { continue }
            for f in subs where f.pathExtension.lowercased() == "strings" && f.lastPathComponent == "Localizable.strings" {
                candidates.append(f)
            }
        }
        guard !candidates.isEmpty else { return nil }

        let rootName = projectRoot.lastPathComponent.replacingOccurrences(of: ".xcodeproj", with: "")
        let needle = "/\(rootName)/\(rootName)/"
        if let hit = candidates.first(where: { $0.path.contains(needle) }) {
            return hit
        }
        return candidates.min(by: { $0.path.count < $1.path.count })
    }
}
