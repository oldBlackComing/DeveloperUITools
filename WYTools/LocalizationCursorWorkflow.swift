//
//  LocalizationCursorWorkflow.swift
//  WYTools
//

import AppKit
import Foundation

final class LocalizationCursorCLICancelToken: @unchecked Sendable {
    nonisolated(unsafe) fileprivate var process: Process?
    func cancel() {
        process?.terminate()
    }
}

struct LocalizationCursorCLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor LocalizationCursorCLIStreamState {
    private var completed = 0
    private var buffer = Data()
    private var stderrText = ""

    func ingestStdout(_ data: Data) -> Int {
        buffer.append(data)
        while true {
            guard let r = buffer.firstRange(of: Data([0x0A])) else { break }
            let lineData = buffer.subdata(in: 0 ..< r.lowerBound)
            buffer.removeSubrange(0 ..< r.upperBound)
            if let s = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("{"), s.hasSuffix("}") {
                completed += 1
            }
        }
        return completed
    }

    func ingestStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return }
        if stderrText.count >= 16_000 { return }
        stderrText.append(s)
    }

    func stderrSnapshot() -> String {
        stderrText
    }
}

/// 生成 Cursor 提示词、尝试拉起 Cursor/CLI、解析译文并写入 `.strings`。
@MainActor
enum LocalizationCursorWorkflow {
    private struct AgentResolution {
        let executableURL: URL
        let arguments: [String]
        let debugHint: String
    }
    
    private static func resolveAgent(
        preferredPath: String,
        prompt: String
    ) -> AgentResolution? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userName = NSUserName()
        let userHomePath = NSHomeDirectoryForUser(userName) ?? "/Users/\(userName)"
        let userHome = URL(fileURLWithPath: userHomePath, isDirectory: true)
        
        let trimmed = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, fm.isExecutableFile(atPath: trimmed) {
            return AgentResolution(
                executableURL: URL(fileURLWithPath: trimmed),
                arguments: ["--trust", "-p", prompt],
                debugHint: "使用用户指定路径：\(trimmed)"
            )
        }
        
        // Cursor 官方安装指南：默认在 ~/.local/bin/agent
        // 另补常见 Homebrew / Cursor 目录、以及 Cursor.app 包内
        var candidates: [String] = [
            "/usr/local/bin/agent",
            "/opt/homebrew/bin/agent",
            home.appendingPathComponent(".local/bin/agent").path,
            userHome.appendingPathComponent(".local/bin/agent").path,
            userHome.appendingPathComponent(".local/bin/cursor-agent").path,
            home.appendingPathComponent("cursor/agent").path,
            home.appendingPathComponent("cursor/bin/agent").path,
            home.appendingPathComponent("cursor/cursor-web/agent").path,
            home.appendingPathComponent("cursor/cursor-web/bin/agent").path,
            userHome.appendingPathComponent("cursor/agent").path,
            userHome.appendingPathComponent("cursor/bin/agent").path,
            userHome.appendingPathComponent("cursor/cursor-web/agent").path,
            userHome.appendingPathComponent("cursor/cursor-web/bin/agent").path,
            "/Applications/Cursor.app/Contents/Resources/app/bin/agent",
            "/Applications/Cursor.app/Contents/Resources/app/out/bin/agent",
        ]
        
        // 额外兜底：扫描 /Users/*/.local/bin/{agent,cursor-agent}
        if let userDirs = try? fm.contentsOfDirectory(atPath: "/Users") {
            for name in userDirs where !name.hasPrefix(".") {
                candidates.append("/Users/\(name)/.local/bin/agent")
                candidates.append("/Users/\(name)/.local/bin/cursor-agent")
            }
        }
        
        if let hit = candidates.first(where: { fm.fileExists(atPath: $0) || fm.isExecutableFile(atPath: $0) }) {
            return AgentResolution(
                executableURL: URL(fileURLWithPath: hit),
                arguments: ["--trust", "-p", prompt],
                debugHint: "使用自动探测命中路径：\(hit)"
            )
        }
        
        // 最后兜底：交互 + login shell（依赖用户 shell 配置）
        if fm.isExecutableFile(atPath: "/bin/zsh") {
            let shellCommand = #"""
setopt nonomatch
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH";
source "$HOME/.zprofile" >/dev/null 2>&1 || true;
source "$HOME/.zshrc" >/dev/null 2>&1 || true;
for c in "$HOME/.local/bin/agent" "$HOME/.local/bin/cursor-agent" "/opt/homebrew/bin/agent" "/usr/local/bin/agent" "/Users/develop/.local/bin/agent" "/Users/develop/.local/bin/cursor-agent"; do
  if [ -e "$c" ]; then
    exec "$c" --trust -p "$1"
  fi
done
for c in /Users/*/.local/bin/agent /Users/*/.local/bin/cursor-agent; do
  if [ -e "$c" ]; then
    exec "$c" --trust -p "$1"
  fi
done
agent --trust -p "$1"
"""#
            return AgentResolution(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-ic", shellCommand, "--", prompt],
                debugHint: "使用 zsh -ic + 显式 source ~/.zprofile ~/.zshrc 兜底"
            )
        }
        
        return nil
    }

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
    
    /// 给 Cursor CLI `agent -p` 的提示词（非 Markdown；只关心输出 JSONL）。
    static func buildAgentTranslationPrompt(
        scanResult: LocalizationCompareScanResult,
        selectedInOrder: [LocalizationMissingEntryID]
    ) -> String {
        var lines: [String] = []
        lines.append("你是本地化翻译助手。请将给定的英文参考翻译成目标语言。")
        lines.append("")
        lines.append("输出要求（必须严格遵守）：")
        lines.append("1) 只输出 JSON Lines，每行一个 JSON 对象，不要 Markdown，不要解释。")
        lines.append(#"2) 每行格式：{"locale":"语言码","key":"原文 key","value":"译文"}"#)
        lines.append("3) 必须覆盖所有条目；不要合并；不要省略。")
        lines.append("4) locale 与 key 必须与条目一致，value 为自然、符合 iOS 习惯的译文。")
        lines.append("")
        lines.append("待翻译条目：")
        
        // 便于取英文参考
        var enByLocaleKey: [String: [String: String]] = [:]
        for lang in scanResult.languages {
            var d: [String: String] = [:]
            for e in lang.missingEntries { d[e.key] = e.englishValue }
            enByLocaleKey[lang.languageCode] = d
        }
        
        for id in selectedInOrder {
            let en = enByLocaleKey[id.languageCode]?[id.key] ?? ""
            lines.append("- locale: \(id.languageCode)")
            lines.append("  key: \(id.key)")
            lines.append("  English: \(en.isEmpty ? "(empty)" : en)")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// 运行 `agent -p` 并将 stdout 写入临时 JSONL 文件；同时按 JSON 行数回调进度。
    static func runAgentToJSONLFile(
        prompt: String,
        agentExecutablePath: String,
        cancelToken: LocalizationCursorCLICancelToken,
        onJSONLLine: (@Sendable (_ completedCount: Int) -> Void)? = nil,
        onConsoleOutput: (@Sendable (_ text: String) -> Void)? = nil
    ) async throws -> URL {
        let outName = "WYTools_cursor_agent_\(Int(Date().timeIntervalSince1970)).jsonl"
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(outName)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: outURL)
        defer { try? fh.close() }
        
        guard let res = resolveAgent(preferredPath: agentExecutablePath, prompt: prompt) else {
            throw LocalizationCursorCLIError(message: "无法解析 Cursor CLI（agent）的可执行路径。请在界面中手动选择 agent 路径。")
        }
        
        let p = Process()
        p.executableURL = res.executableURL
        p.arguments = res.arguments
        let promptChars = prompt.count
        onConsoleOutput?("[debug] \(res.debugHint)\n")
        onConsoleOutput?("[debug] command=\(res.executableURL.path) args=\(res.arguments.count) prompt_chars=\(promptChars)\n")
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        cancelToken.process = p

        let state = LocalizationCursorCLIStreamState()
        
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }

            // 写文件：原样追加
            try? fh.write(contentsOf: data)
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                onConsoleOutput?(s)
            }

            Task {
                let done = await state.ingestStdout(data)
                onJSONLLine?(done)
            }
        }
        
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                onConsoleOutput?(s)
            }
            Task { await state.ingestStderr(data) }
        }
        
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationReason == .uncaughtSignal {
                    cont.resume(throwing: LocalizationCursorCLIError(message: "已取消。"))
                    return
                }
                if proc.terminationStatus == 0 {
                    cont.resume(returning: outURL)
                } else {
                    Task {
                        let err = (await state.stderrSnapshot()).trimmingCharacters(in: .whitespacesAndNewlines)
                        let tail = err.isEmpty ? "" : "\n\(err)"
                        cont.resume(
                            throwing: LocalizationCursorCLIError(
                                message: "Cursor CLI 运行失败（exit=\(proc.terminationStatus)）。\n\(res.debugHint)\n请确认终端中 `agent -p \"hi\"` 可用。\n\(tail)"
                            )
                        )
                    }
                }
            }
            do {
                try p.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(
                    throwing: LocalizationCursorCLIError(
                        message: "无法启动 Cursor CLI：\(error.localizedDescription)。请确认命令 `agent` 已安装且在常见路径或 PATH 中可用。"
                    )
                )
            }
        }
    }
    
    /// 在应用内以与一键翻译相同的命令解析链路做一次 CLI 诊断，输出到内置终端面板。
    static func runEmbeddedTerminalDiagnosis(
        agentExecutablePath: String,
        cancelToken: LocalizationCursorCLICancelToken,
        onConsoleOutput: (@Sendable (_ text: String) -> Void)? = nil
    ) async throws {
        let outputURL = try await runAgentToJSONLFile(
            prompt: "hi",
            agentExecutablePath: agentExecutablePath,
            cancelToken: cancelToken,
            onJSONLLine: nil,
            onConsoleOutput: onConsoleOutput
        )
        onConsoleOutput?("\n[diagnose] 结束：exit=0\n")
        try? FileManager.default.removeItem(at: outputURL)
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
    
    struct ParsedJSONLPreview: Sendable {
        let rows: [(locale: String, key: String, value: String)]
        let skippedLineCount: Int
    }

    /// 仅解析 JSONL 为预览行（不写文件）。
    static func parseJSONLPreview(
        text: String,
        selected: Set<LocalizationMissingEntryID>
    ) throws -> ParsedJSONLPreview {
        var rows: [(locale: String, key: String, value: String)] = []
        rows.reserveCapacity(selected.count)
        var skipped = 0

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
            rows.append((locale: match.languageCode, key: keyN, value: value))
        }

        if rows.isEmpty {
            throw AppendError.noValidLines
        }
        return ParsedJSONLPreview(rows: rows, skippedLineCount: skipped)
    }

    /// 解析 JSONL，将 `locale`+`key` 在 `selected` 中的条目追加到对应语言的主 `Localizable.strings` 末尾。
    static func applyPastedJSONL(
        text: String,
        projectRoot: URL,
        scanResult: LocalizationCompareScanResult,
        selected: Set<LocalizationMissingEntryID>
    ) throws -> AppendReport {
        var pairs: [String: [(key: String, value: String)]] = [:]
        var parseNotes: [String] = []
        let parsed = try parseJSONLPreview(text: text, selected: selected)
        var skipped = parsed.skippedLineCount
        for row in parsed.rows {
            pairs[row.locale, default: []].append((key: row.key, value: row.value))
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

    // MARK: Align

    /// 将目标语言的 `Localizable.strings` 按英文 `Localizable.strings` 的 key 顺序对齐重写。
    /// - Missing：若该语言缺省某个 key，会写入注释占位（不会生效），并带英文参考。
    static func alignLocalizableStringsToEnglishOrder(
        projectRoot: URL,
        scanResult: LocalizationCompareScanResult,
        targetLocales: [String]
    ) throws -> AppendReport {
        let lprojs = try LocalizationCompareScanner.includedLprojRoots(projectRoot: projectRoot)

        guard let englishFile = try pickEnglishLocalizableStrings(lprojRoots: lprojs, projectRoot: projectRoot) else {
            return AppendReport(
                appendedLineCount: 0,
                skippedLineCount: 0,
                messages: ["未找到英文 Localizable.strings，已跳过对齐。"]
            )
        }

        let englishText = (try? readTextFile(url: englishFile)) ?? ""
        let englishDict = (NSDictionary(contentsOf: englishFile) as? [String: String]) ?? [:]

        var messages: [String] = []
        var rewrittenCount = 0

        for locale in Array(Set(targetLocales)).sorted() {
            guard let fileURL = try pickPrimaryLocalizableStrings(
                localeDisplayCode: locale,
                lprojRoots: lprojs,
                projectRoot: projectRoot
            ) else {
                messages.append("`\(locale)`：未找到 Localizable.strings，跳过对齐。")
                continue
            }

            let existing = (NSDictionary(contentsOf: fileURL) as? [String: String]) ?? [:]
            let aligned = buildAlignedStringsFileByMirroringEnglish(
                locale: locale,
                englishText: englishText,
                englishByKey: englishDict,
                localeByKey: existing
            )
            try aligned.write(to: fileURL, atomically: true, encoding: .utf8)
            rewrittenCount += 1
            messages.append("`\(locale)`：已按英文顺序对齐并重写 `\(fileURL.path)`。")
        }

        return AppendReport(appendedLineCount: rewrittenCount, skippedLineCount: 0, messages: messages)
    }

    private static func pickEnglishLocalizableStrings(lprojRoots: [URL], projectRoot: URL) throws -> URL? {
        // 优先：en / en-*；其次 Base
        let preferred: [String] = ["en", "en-US", "en-GB", "Base"]
        for code in preferred {
            if let u = try pickPrimaryLocalizableStrings(localeDisplayCode: code, lprojRoots: lprojRoots, projectRoot: projectRoot) {
                return u
            }
        }
        return nil
    }

    /// 将英文文件每一行当作模板镜像输出：注释/空行原样保留；遇到 `"key" = "..." ;` 行则替换为该语言对应 key 的翻译。
    /// 这样每个语言文件的行号与英文文件严格对应。
    private static func buildAlignedStringsFileByMirroringEnglish(
        locale: String,
        englishText: String,
        englishByKey: [String: String],
        localeByKey: [String: String]
    ) -> String {
        let rawLines = englishText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        out.reserveCapacity(rawLines.count + 16)

        // 匹配一行 key-value：保留行首缩进
        let re = try? NSRegularExpression(
            pattern: #"^(\s*)"((?:\\.|[^"\\])*)"\s*=\s*"(?:\\.|[^"\\])*"\s*;\s*$"#,
            options: []
        )

        var englishKeySet = Set<String>()

        for line in rawLines {
            guard let re else {
                out.append(line)
                continue
            }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: line, options: [], range: range),
                  m.numberOfRanges >= 3
            else {
                out.append(line)
                continue
            }

            let indent = ns.substring(with: m.range(at: 1))
            let rawKey = ns.substring(with: m.range(at: 2))
            let key = unescapeStringsLiteral(rawKey).precomposedStringWithCanonicalMapping
            englishKeySet.insert(key)

            if let v = localeByKey[key] {
                out.append(indent + escapeStringsLine(key: key, value: v))
            } else {
                let en = englishByKey[key] ?? ""
                let placeholder = escapeStringsLine(key: key, value: en)
                // 占位：同一行位置用注释包住，保证不生效且与英文行号对齐
                out.append(indent + "/* " + placeholder + " */")
            }
        }

        // 额外 key：追加到底部（不影响与英文的逐行对齐部分）
        let extraKeys = localeByKey.keys.filter { !englishKeySet.contains($0) }.sorted()
        if !extraKeys.isEmpty {
            out.append("")
            out.append("/* Extra keys (not in English reference) */")
            for key in extraKeys {
                if let v = localeByKey[key] {
                    out.append(escapeStringsLine(key: key, value: v))
                }
            }
        }

        return out.joined(separator: "\n")
    }

    private static func unescapeStringsLiteral(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let ch = it.next() {
            if ch != "\\" {
                out.append(ch)
                continue
            }
            guard let n = it.next() else { break }
            switch n {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            default:
                out.append(n)
            }
        }
        return out
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
