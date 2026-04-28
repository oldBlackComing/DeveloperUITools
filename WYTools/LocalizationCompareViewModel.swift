//
//  LocalizationCompareViewModel.swift
//  WYTools
//

import AppKit
import Foundation
import SwiftUI

/// 「第 1 步」完成后弹出的引导页数据。
struct CursorLocalizationGuidePayload: Identifiable {
    let id = UUID()
    let launchSummary: String
    let tempFilePath: String?
}

@MainActor
@Observable
final class LocalizationCompareViewModel {
    var selectedFolderPath: String = ""
    var isScanning = false
    var errorMessage: String?
    var scanResult: LocalizationCompareScanResult?

    /// Active locale tab (horizontal).
    var selectedLanguageTab: String = ""

    /// Per missing row; default all selected after scan.
    var selectedMissingEntryIDs: Set<LocalizationMissingEntryID> = []

    var debugTraceKey: String = "10 consecutive works score above 85"
    var debugTraceOutput: String = ""
    var isTracingKey = false

    /// Cursor / 追加流程提示（成功或说明）
    var workflowMessage: String?
    
    /// Cursor CLI（agent）一键翻译状态
    var isCursorCLIRunning: Bool = false
    /// 可选：用户手动指定 `agent` 可执行文件路径（用于 App 环境找不到 PATH 时兜底）
    var cursorCLIAgentExecutablePath: String = UserDefaults.standard.string(forKey: "WYTools.CursorCLIAgentExecutablePath") ?? ""
    var cursorCLITotalCount: Int = 0
    var cursorCLICompletedCount: Int = 0
    var cursorCLICurrentLocale: String = ""
    var cursorCLICurrentKey: String = ""
    var cursorCLICurrentSourceText: String = ""
    var showCursorCLITerminalPanel: Bool = true
    var cursorCLITerminalOutput: String = ""
    private var cursorCLITerminalPendingOutput: String = ""
    private var cursorCLITerminalFlushScheduled = false
    private var cursorCLICancelToken = LocalizationCursorCLICancelToken()

    var showAppendTranslationSheet = false
    var appendPasteText = ""

    /// 点击「用 Cursor 翻译」后自动弹出，说明接下来在 Cursor 与本应用各做什么。
    var cursorGuidePayload: CursorLocalizationGuidePayload?

    var isMachineTranslating = false
    /// 右侧预览区显示的翻译结果（先翻译、后应用写入）。
    var translatedPreviewByID: [LocalizationMissingEntryID: String] = [:]
    
    /// 本机翻译进度（仅用于 UI 展示）
    var machineTranslationTotalCount: Int = 0
    var machineTranslationCompletedCount: Int = 0
    var machineTranslationCurrentLocale: String = ""
    var machineTranslationCurrentKey: String = ""
    var machineTranslationCurrentSourceText: String = ""

    /// 本机翻译语言包需下载时展示；用户点「帮我下载」后触发 `prepareTranslation()`。
    var showTranslationLanguageDownloadSheet = false
    var translationLocalesNeedingDownload: [String] = []
    private var pendingOnDeviceTranslationItems: [LocalizationMachineTranslationItem] = []
    /// 用户取消下载后，本次会话内不再反复弹窗提示（避免死循环）。
    private var suppressedDownloadLocales: Set<String> = []

    private var securityScopedFolderURL: URL?
    private var isAccessingSecurityScopedResource = false

    func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 Xcode 工程所在文件夹（包含 .xcodeproj 的上级目录亦可）。"
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        stopSecurityScopedAccessIfNeeded()

        securityScopedFolderURL = url
        if url.startAccessingSecurityScopedResource() {
            isAccessingSecurityScopedResource = true
        }

        selectedFolderPath = url.path
        scanResult = nil
        errorMessage = nil
        selectedLanguageTab = ""
        selectedMissingEntryIDs = []
        workflowMessage = nil
        isCursorCLIRunning = false
        cursorCLITotalCount = 0
        cursorCLICompletedCount = 0
        cursorCLICurrentLocale = ""
        cursorCLICurrentKey = ""
        cursorCLICurrentSourceText = ""
        showCursorCLITerminalPanel = true
        cursorCLITerminalOutput = ""
        cursorCLICancelToken = LocalizationCursorCLICancelToken()
        appendPasteText = ""
        showAppendTranslationSheet = false
        cursorGuidePayload = nil
        isMachineTranslating = false
        showTranslationLanguageDownloadSheet = false
        translationLocalesNeedingDownload = []
        pendingOnDeviceTranslationItems = []
        suppressedDownloadLocales = []
        translatedPreviewByID = [:]
        machineTranslationTotalCount = 0
        machineTranslationCompletedCount = 0
        machineTranslationCurrentLocale = ""
        machineTranslationCurrentKey = ""
        machineTranslationCurrentSourceText = ""
    }

    func scan() async {
        guard let root = securityScopedFolderURL else {
            errorMessage = "请先选择文件夹。"
            return
        }

        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        do {
            let result = try await LocalizationCompareScanner.scan(projectRoot: root)
            scanResult = result
            let ids = result.languages.flatMap { lang in
                lang.missingEntries.map { LocalizationMissingEntryID(languageCode: lang.languageCode, key: $0.key) }
            }
            selectedMissingEntryIDs = Set(ids)
            let codes = result.languages.map(\.languageCode).sorted()
            if selectedLanguageTab.isEmpty || !codes.contains(selectedLanguageTab) {
                selectedLanguageTab = codes.first ?? ""
            }
        } catch {
            scanResult = nil
            selectedLanguageTab = ""
            selectedMissingEntryIDs = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearSelection() {
        stopSecurityScopedAccessIfNeeded()
        securityScopedFolderURL = nil
        selectedFolderPath = ""
        scanResult = nil
        errorMessage = nil
        selectedLanguageTab = ""
        selectedMissingEntryIDs = []
        workflowMessage = nil
        isCursorCLIRunning = false
        cursorCLITotalCount = 0
        cursorCLICompletedCount = 0
        cursorCLICurrentLocale = ""
        cursorCLICurrentKey = ""
        cursorCLICurrentSourceText = ""
        showCursorCLITerminalPanel = true
        cursorCLITerminalOutput = ""
        cursorCLICancelToken = LocalizationCursorCLICancelToken()
        appendPasteText = ""
        showAppendTranslationSheet = false
        cursorGuidePayload = nil
        isMachineTranslating = false
        showTranslationLanguageDownloadSheet = false
        translationLocalesNeedingDownload = []
        pendingOnDeviceTranslationItems = []
        suppressedDownloadLocales = []
        translatedPreviewByID = [:]
        machineTranslationTotalCount = 0
        machineTranslationCompletedCount = 0
        machineTranslationCurrentLocale = ""
        machineTranslationCurrentKey = ""
        machineTranslationCurrentSourceText = ""
    }

    func setEntrySelected(_ id: LocalizationMissingEntryID, isOn: Bool) {
        if isOn {
            selectedMissingEntryIDs.insert(id)
        } else {
            selectedMissingEntryIDs.remove(id)
        }
    }

    func selectAllEntries() {
        guard let scanResult else { return }
        let ids = scanResult.languages.flatMap { lang in
            lang.missingEntries.map { LocalizationMissingEntryID(languageCode: lang.languageCode, key: $0.key) }
        }
        selectedMissingEntryIDs = Set(ids)
    }

    func deselectAllEntries() {
        selectedMissingEntryIDs = []
    }

    func selectAllInCurrentTab() {
        guard let scanResult, !selectedLanguageTab.isEmpty else { return }
        guard let lang = scanResult.languages.first(where: { $0.languageCode == selectedLanguageTab }) else { return }
        for entry in lang.missingEntries {
            selectedMissingEntryIDs.insert(LocalizationMissingEntryID(languageCode: lang.languageCode, key: entry.key))
        }
    }

    func deselectAllInCurrentTab() {
        guard let scanResult, !selectedLanguageTab.isEmpty else { return }
        guard let lang = scanResult.languages.first(where: { $0.languageCode == selectedLanguageTab }) else { return }
        for entry in lang.missingEntries {
            selectedMissingEntryIDs.remove(LocalizationMissingEntryID(languageCode: lang.languageCode, key: entry.key))
        }
    }

    /// Console-style trace for one entry key (same logic as `LocalizationCompareScanner.debugComparisonTrace`).
    func runKeyTrace() async {
        guard let root = securityScopedFolderURL else {
            debugTraceOutput = "请先选择文件夹。"
            return
        }
        let key = debugTraceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            debugTraceOutput = "请输入要追踪的 key。"
            return
        }
        isTracingKey = true
        debugTraceOutput = ""
        defer { isTracingKey = false }
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try LocalizationCompareScanner.debugComparisonTrace(projectRoot: root, entryKey: key)
            }.value
            debugTraceOutput = text
        } catch {
            debugTraceOutput = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// 生成翻译提示词，复制到剪贴板，并尝试用 `cursor` CLI 或 `open -a Cursor` 打开临时 `.md`。
    func invokeCursorForSelectedTranslations() {
        cursorGuidePayload = nil
        guard let root = securityScopedFolderURL, let scan = scanResult else {
            workflowMessage = "请先选择文件夹并完成扫描。"
            return
        }
        let chosen = selectedMissingEntryIDs
        guard !chosen.isEmpty else {
            workflowMessage = "请先勾选要翻译的缺失条目。"
            return
        }
        let prompt = LocalizationCursorWorkflow.buildTranslationPrompt(
            projectRootPath: root.path,
            scanResult: scan,
            selected: chosen
        )
        let result = LocalizationCursorWorkflow.copyPromptAndOpenInCursor(prompt: prompt)
        workflowMessage = result.summary
        cursorGuidePayload = CursorLocalizationGuidePayload(
            launchSummary: result.summary,
            tempFilePath: result.tempFileURL?.path
        )
    }
    
    /// 一键：调用 Cursor CLI `agent -p` 分批生成 JSONL，并写入右侧预览（不自动写文件）。
    func translateWithCursorCLIToPreview() async {
        cursorGuidePayload = nil
        guard securityScopedFolderURL != nil, let scan = scanResult else {
            workflowMessage = "请先选择文件夹并完成扫描。"
            return
        }
        let chosen = selectedMissingEntryIDs
        guard !chosen.isEmpty else {
            workflowMessage = "请先勾选要翻译的缺失条目。"
            return
        }
        guard !isCursorCLIRunning else { return }
        
        // 固定顺序：locale 升序、key 升序；用于进度与“当前正在翻译”的展示
        let orderedIDs: [LocalizationMissingEntryID] = chosen.sorted {
            if $0.languageCode == $1.languageCode { return $0.key < $1.key }
            return $0.languageCode < $1.languageCode
        }
        
        var enByID: [LocalizationMissingEntryID: String] = [:]
        enByID.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            guard let lang = scan.languages.first(where: { $0.languageCode == id.languageCode }),
                  let entry = lang.missingEntries.first(where: { $0.key == id.key })
            else { continue }
            enByID[id] = entry.englishValue
        }
        
        cursorCLITotalCount = orderedIDs.count
        cursorCLICompletedCount = 0
        cursorCLICurrentLocale = ""
        cursorCLICurrentKey = ""
        cursorCLICurrentSourceText = ""
        showCursorCLITerminalPanel = true
        cursorCLITerminalOutput = ""
        workflowMessage = "正在通过 Cursor CLI 生成 JSONL…"
        
        isCursorCLIRunning = true
        cursorCLICancelToken = LocalizationCursorCLICancelToken()
        defer { isCursorCLIRunning = false }

        let batchSize = 20
        var updated = translatedPreviewByID
        updated.reserveCapacity(updated.count + orderedIDs.count)
        var totalGenerated = 0
        var totalSkipped = 0
        var completedBase = 0

        do {
            for start in stride(from: 0, to: orderedIDs.count, by: batchSize) {
                let end = min(start + batchSize, orderedIDs.count)
                let batchIDs = Array(orderedIDs[start ..< end])
                let batchSet = Set(batchIDs)
                let prompt = LocalizationCursorWorkflow.buildAgentTranslationPrompt(
                    scanResult: scan,
                    selectedInOrder: batchIDs
                )

                workflowMessage = "Cursor CLI 分批翻译中（\(start / batchSize + 1)/\((orderedIDs.count + batchSize - 1) / batchSize)）…"

                let outputURL = try await LocalizationCursorWorkflow.runAgentToJSONLFile(
                    prompt: prompt,
                    agentExecutablePath: cursorCLIAgentExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines),
                    cancelToken: cursorCLICancelToken,
                    onJSONLLine: { [weak self] completed in
                        guard let self else { return }
                        Task { @MainActor in
                            self.cursorCLICompletedCount = min(completedBase + completed, self.cursorCLITotalCount)
                            let idx = max(min(completedBase + completed, orderedIDs.count) - 1, 0)
                            if orderedIDs.indices.contains(idx) {
                                let id = orderedIDs[idx]
                                self.cursorCLICurrentLocale = id.languageCode
                                self.cursorCLICurrentKey = id.key
                                self.cursorCLICurrentSourceText = enByID[id] ?? ""
                            }
                        }
                    },
                    onConsoleOutput: { [weak self] text in
                        guard let self else { return }
                        Task { @MainActor in
                            self.enqueueCursorCLITerminalOutput(text)
                        }
                    }
                )

                let text = try String(contentsOf: outputURL, encoding: .utf8)
                appendPasteText = text
                let parsed = try LocalizationCursorWorkflow.parseJSONLPreview(
                    text: text,
                    selected: batchSet
                )
                for row in parsed.rows {
                    let id = LocalizationMissingEntryID(languageCode: row.locale, key: row.key)
                    updated[id] = row.value
                }
                totalGenerated += parsed.rows.count
                totalSkipped += parsed.skippedLineCount
                completedBase += parsed.rows.count
                cursorCLICompletedCount = min(completedBase, cursorCLITotalCount)
                translatedPreviewByID = updated
            }

            workflowMessage = "已分批生成 \(totalGenerated) 条 Cursor 预览；跳过 \(totalSkipped) 行。请在右侧检查后点击「应用预览到工程」。"
        } catch {
            translatedPreviewByID = updated
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
    
    func cancelCursorCLITranslation() {
        cursorCLICancelToken.cancel()
        workflowMessage = "已取消 Cursor CLI 翻译任务。"
    }
    
    func runCursorCLIDiagnosis() async {
        guard !isCursorCLIRunning else { return }
        isCursorCLIRunning = true
        cursorCLICancelToken = LocalizationCursorCLICancelToken()
        showCursorCLITerminalPanel = true
        cursorCLITerminalOutput = ""
        workflowMessage = "正在诊断 Cursor CLI…"
        defer { isCursorCLIRunning = false }
        
        do {
            try await LocalizationCursorWorkflow.runEmbeddedTerminalDiagnosis(
                agentExecutablePath: cursorCLIAgentExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines),
                cancelToken: cursorCLICancelToken,
                onConsoleOutput: { [weak self] text in
                    guard let self else { return }
                    Task { @MainActor in
                        self.enqueueCursorCLITerminalOutput(text)
                    }
                }
            )
            workflowMessage = "诊断完成。"
        } catch {
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func pickCursorCLIAgentExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择 Cursor CLI 的 `agent` 可执行文件（例如 /usr/local/bin/agent）。"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cursorCLIAgentExecutablePath = url.path
        UserDefaults.standard.set(url.path, forKey: "WYTools.CursorCLIAgentExecutablePath")
        workflowMessage = "已设置 agent 路径：\(url.path)"
    }
    
    func clearCursorCLITerminalOutput() {
        cursorCLITerminalOutput = ""
        cursorCLITerminalPendingOutput = ""
    }
    
    private func enqueueCursorCLITerminalOutput(_ text: String) {
        guard !text.isEmpty else { return }
        // 高频输出先聚合后批量刷新，避免 UI 高频重排导致卡顿。
        cursorCLITerminalPendingOutput.append(text)
        if cursorCLITerminalPendingOutput.count > 12_000 {
            cursorCLITerminalPendingOutput = String(cursorCLITerminalPendingOutput.suffix(8_000))
        }
        guard !cursorCLITerminalFlushScheduled else { return }
        cursorCLITerminalFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run {
                guard let self else { return }
                self.cursorCLITerminalFlushScheduled = false
                guard !self.cursorCLITerminalPendingOutput.isEmpty else { return }
                self.cursorCLITerminalOutput.append(self.cursorCLITerminalPendingOutput)
                self.cursorCLITerminalPendingOutput = ""
                if self.cursorCLITerminalOutput.count > 24_000 {
                    self.cursorCLITerminalOutput = String(self.cursorCLITerminalOutput.suffix(24_000))
                }
            }
        }
    }

    /// 复制发给 Cursor 的推荐口令（与提示文件内一致）。
    func copyCursorChatOneLinerToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(LocalizationCursorWorkflow.cursorChatOneLiner, forType: .string)
        workflowMessage = "已复制推荐口令到剪贴板，可在 Cursor 聊天里粘贴发送。"
    }

    func copyTempPromptPathToPasteboard(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
        workflowMessage = "已复制临时文件路径到剪贴板。"
    }

    func pasteAppendTextFromClipboard() {
        appendPasteText = NSPasteboard.general.string(forType: .string) ?? ""
    }

    func applyAppendFromPastedJSONL(dismissCursorGuideOnSuccess: Bool = false) {
        guard let root = securityScopedFolderURL, let scan = scanResult else {
            workflowMessage = "请先选择文件夹并完成扫描。"
            return
        }
        let text = appendPasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            workflowMessage = "请粘贴 Cursor 返回的 JSONL。"
            return
        }
        do {
            let report = try LocalizationCursorWorkflow.applyPastedJSONL(
                text: text,
                projectRoot: root,
                scanResult: scan,
                selected: selectedMissingEntryIDs
            )
            let detail = report.messages.joined(separator: "\n")
            let summary = "已写入 \(report.appendedLineCount) 条；跳过 \(report.skippedLineCount) 行。\n\(detail)"
            showAppendTranslationSheet = false
            appendPasteText = ""
            if dismissCursorGuideOnSuccess {
                cursorGuidePayload = nil
            }
            Task {
                await self.scan()
                self.workflowMessage = summary
            }
        } catch {
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 引导页内：从剪贴板读取 JSONL 并写入；成功则关闭引导页。
    func applyAppendFromClipboardThroughGuide() {
        pasteAppendTextFromClipboard()
        applyAppendFromPastedJSONL(dismissCursorGuideOnSuccess: true)
    }

    /// 关闭引导并打开手动粘贴 sheet（需校对 AI 输出时）。
    func openManualAppendSheetFromGuide() {
        cursorGuidePayload = nil
        showAppendTranslationSheet = true
    }

    /// 使用 Apple 本机 Translation 翻译勾选条目并生成右侧预览（不写文件；需 macOS 15+）。
    func machineTranslateSelectedToPreview(onDeviceCoordinator: OnDeviceTranslationCoordinator) async {
        guard #available(macOS 15.0, *) else {
            workflowMessage = LocalizationOnDeviceTranslationError.needsMacOS15.errorDescription
            return
        }
        guard let root = securityScopedFolderURL, let currentScan = scanResult else {
            workflowMessage = "请先选择文件夹并完成扫描。"
            return
        }
        let chosen = selectedMissingEntryIDs
        guard !chosen.isEmpty else {
            workflowMessage = "请先勾选要翻译的缺失条目。"
            return
        }
        let items = buildMachineTranslationItems(scan: currentScan, selected: chosen)
        guard !items.isEmpty else {
            workflowMessage = "勾选项与当前扫描结果不匹配，请先重新扫描。"
            return
        }

        let localeCodes = Array(Set(items.map(\.locale)))
        if let bad = await LocalizationOnDeviceTranslationSupport.firstUnsupportedLprojCode(fromEnglishToLprojCodes: localeCodes) {
            workflowMessage = LocalizationOnDeviceTranslationError.unsupportedLanguagePair(locale: bad).errorDescription
            return
        }

        let needDownload = await LocalizationOnDeviceTranslationSupport.lprojCodesNeedingDownload(fromEnglishToLprojCodes: localeCodes)
        let filteredNeedDownload = needDownload.filter { !suppressedDownloadLocales.contains($0) }
        if !filteredNeedDownload.isEmpty {
            pendingOnDeviceTranslationItems = items
            translationLocalesNeedingDownload = filteredNeedDownload
            showTranslationLanguageDownloadSheet = true
            workflowMessage = "以下语言需先下载本机翻译语言包，请点击「帮我下载」：\(filteredNeedDownload.joined(separator: ", "))。"
            return
        } else if !needDownload.isEmpty {
            workflowMessage = "你已取消下载以下语言包（本次不再弹窗）：\(needDownload.joined(separator: ", "))。如需再次下载，可在系统设置里下载后再点翻译。"
            return
        }

        await performOnDeviceTranslationPreview(items: items, projectRoot: root, scan: currentScan, onDeviceCoordinator: onDeviceCoordinator)
    }

    func cancelTranslationLanguageDownload() {
        showTranslationLanguageDownloadSheet = false
        suppressedDownloadLocales.formUnion(translationLocalesNeedingDownload)
        translationLocalesNeedingDownload = []
        pendingOnDeviceTranslationItems = []
    }

    /// 在「帮我下载」后调用：下载语言包并继续写入译文。
    func downloadTranslationLanguagePacksAndTranslate(onDeviceCoordinator: OnDeviceTranslationCoordinator) async {
        guard #available(macOS 15.0, *) else { return }
        guard !pendingOnDeviceTranslationItems.isEmpty,
              let root = securityScopedFolderURL,
              let currentScan = scanResult
        else {
            workflowMessage = "没有待处理的翻译任务，请先勾选并再次点击本机翻译。"
            showTranslationLanguageDownloadSheet = false
            return
        }

        isMachineTranslating = true
        defer { isMachineTranslating = false }

        do {
            try await LocalizationOnDeviceTranslationBatch.prepareDownloads(
                forLprojLanguageCodes: translationLocalesNeedingDownload,
                coordinator: onDeviceCoordinator
            )
            showTranslationLanguageDownloadSheet = false
            translationLocalesNeedingDownload = []
            let items = pendingOnDeviceTranslationItems
            pendingOnDeviceTranslationItems = []
            workflowMessage = "语言包下载请求已提交。正在尝试生成翻译预览…"
            await performOnDeviceTranslationPreview(items: items, projectRoot: root, scan: currentScan, onDeviceCoordinator: onDeviceCoordinator)
        } catch {
            // 用户取消下载时，避免再次触发弹窗导致“死循环”
            suppressedDownloadLocales.formUnion(translationLocalesNeedingDownload)
            showTranslationLanguageDownloadSheet = false
            translationLocalesNeedingDownload = []
            pendingOnDeviceTranslationItems = []
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performOnDeviceTranslationPreview(
        items: [LocalizationMachineTranslationItem],
        projectRoot: URL,
        scan: LocalizationCompareScanResult,
        onDeviceCoordinator: OnDeviceTranslationCoordinator
    ) async {
        isMachineTranslating = true
        defer { isMachineTranslating = false }
        
        machineTranslationTotalCount = items.count
        machineTranslationCompletedCount = 0
        machineTranslationCurrentLocale = ""
        machineTranslationCurrentKey = ""
        machineTranslationCurrentSourceText = ""

        do {
            let rows = try await LocalizationOnDeviceTranslationBatch.translateAll(
                items: items,
                coordinator: onDeviceCoordinator,
                onProgress: { progress in
                    Task { @MainActor in
                        self.machineTranslationTotalCount = progress.total
                        self.machineTranslationCompletedCount = progress.completed
                        self.machineTranslationCurrentLocale = progress.locale
                        self.machineTranslationCurrentKey = progress.key
                        self.machineTranslationCurrentSourceText = progress.sourceText
                    }
                }
            )
            var updated = translatedPreviewByID
            updated.reserveCapacity(updated.count + rows.count)
            for r in rows {
                let id = LocalizationMissingEntryID(languageCode: r.locale, key: r.key)
                updated[id] = r.value
            }
            translatedPreviewByID = updated
            workflowMessage = "已生成 \(rows.count) 条翻译预览。请在右侧检查后点击「应用」写入工程。"
        } catch {
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 将右侧预览中已生成的勾选项写入工程文件（追加到末尾）。
    func applyTranslatedPreviewToFiles() async {
        guard let root = securityScopedFolderURL, let currentScan = scanResult else {
            workflowMessage = "请先选择文件夹并完成扫描。"
            return
        }
        let chosen = selectedMissingEntryIDs
        guard !chosen.isEmpty else {
            workflowMessage = "请先勾选要写入的条目。"
            return
        }

        var rows: [(locale: String, key: String, value: String)] = []
        rows.reserveCapacity(chosen.count)
        var missingPreview = 0
        for id in chosen {
            guard let value = translatedPreviewByID[id], !value.isEmpty else {
                missingPreview += 1
                continue
            }
            rows.append((locale: id.languageCode, key: id.key, value: value))
        }
        guard !rows.isEmpty else {
            workflowMessage = missingPreview > 0
                ? "右侧暂无可应用的译文（有 \(missingPreview) 条未生成预览）。请先点「本机翻译」生成预览。"
                : "右侧暂无可应用的译文。"
            return
        }

        do {
            let jsonl = try LocalizationOnDeviceTranslationBatch.encodeJSONL(rows: rows)
            let report = try LocalizationCursorWorkflow.applyPastedJSONL(
                text: jsonl,
                projectRoot: root,
                scanResult: currentScan,
                selected: selectedMissingEntryIDs
            )
            let detail = report.messages.joined(separator: "\n")
            let summary = "已应用 \(report.appendedLineCount) 条；跳过 \(report.skippedLineCount) 行。\n\(detail)"
            await self.scan()
            workflowMessage = summary
        } catch {
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 独立功能：将目标语言的 `Localizable.strings` 按英文 key 顺序对齐重写；缺译用注释占位。
    func alignStringsFilesToEnglishOrder(locales: [String]? = nil) async {
        guard let root = securityScopedFolderURL, let currentScan = scanResult else {
            workflowMessage = "请先选择文件夹并完成扫描。"
            return
        }
        let targetLocales: [String]
        if let locales, !locales.isEmpty {
            targetLocales = locales
        } else {
            // 默认：当前扫描出来的全部语言
            targetLocales = currentScan.languages.map(\.languageCode)
        }
        guard !targetLocales.isEmpty else {
            workflowMessage = "没有可对齐的语言。"
            return
        }

        do {
            let report = try LocalizationCursorWorkflow.alignLocalizableStringsToEnglishOrder(
                projectRoot: root,
                scanResult: currentScan,
                targetLocales: targetLocales
            )
            let detail = report.messages.joined(separator: "\n")
            workflowMessage = "已对齐重写 \(report.appendedLineCount) 个文件。\n\(detail)"
        } catch {
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func buildMachineTranslationItems(
        scan: LocalizationCompareScanResult,
        selected: Set<LocalizationMissingEntryID>
    ) -> [LocalizationMachineTranslationItem] {
        var out: [LocalizationMachineTranslationItem] = []
        out.reserveCapacity(selected.count)
        for id in selected {
            guard let lang = scan.languages.first(where: { $0.languageCode == id.languageCode }),
                  let entry = lang.missingEntries.first(where: { $0.key == id.key })
            else { continue }
            out.append(
                LocalizationMachineTranslationItem(
                    locale: lang.languageCode,
                    key: entry.key,
                    englishSource: entry.englishValue
                )
            )
        }
        return out
    }

    private func stopSecurityScopedAccessIfNeeded() {
        if let url = securityScopedFolderURL, isAccessingSecurityScopedResource {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
        securityScopedFolderURL = nil
    }
}
