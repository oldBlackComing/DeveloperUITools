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

    var showAppendTranslationSheet = false
    var appendPasteText = ""

    /// 点击「用 Cursor 翻译」后自动弹出，说明接下来在 Cursor 与本应用各做什么。
    var cursorGuidePayload: CursorLocalizationGuidePayload?

    var isMachineTranslating = false

    /// 本机翻译语言包需下载时展示；用户点「帮我下载」后触发 `prepareTranslation()`。
    var showTranslationLanguageDownloadSheet = false
    var translationLocalesNeedingDownload: [String] = []
    private var pendingOnDeviceTranslationItems: [LocalizationMachineTranslationItem] = []

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
        appendPasteText = ""
        showAppendTranslationSheet = false
        cursorGuidePayload = nil
        isMachineTranslating = false
        showTranslationLanguageDownloadSheet = false
        translationLocalesNeedingDownload = []
        pendingOnDeviceTranslationItems = []
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
        appendPasteText = ""
        showAppendTranslationSheet = false
        cursorGuidePayload = nil
        isMachineTranslating = false
        showTranslationLanguageDownloadSheet = false
        translationLocalesNeedingDownload = []
        pendingOnDeviceTranslationItems = []
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

    /// 使用 Apple 本机 Translation 翻译勾选条目并写入 `Localizable.strings`（需 macOS 15+）。
    func machineTranslateSelectedAndApply(onDeviceCoordinator: OnDeviceTranslationCoordinator) async {
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
        if !needDownload.isEmpty {
            pendingOnDeviceTranslationItems = items
            translationLocalesNeedingDownload = needDownload
            showTranslationLanguageDownloadSheet = true
            workflowMessage = "以下语言需先下载本机翻译语言包，请点击「帮我下载」：\(needDownload.joined(separator: ", "))。"
            return
        }

        await performOnDeviceTranslationWrite(items: items, projectRoot: root, scan: currentScan, onDeviceCoordinator: onDeviceCoordinator)
    }

    func cancelTranslationLanguageDownload() {
        showTranslationLanguageDownloadSheet = false
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
            workflowMessage = "语言包下载请求已提交。正在尝试写入译文…"
            await performOnDeviceTranslationWrite(items: items, projectRoot: root, scan: currentScan, onDeviceCoordinator: onDeviceCoordinator)
        } catch {
            workflowMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performOnDeviceTranslationWrite(
        items: [LocalizationMachineTranslationItem],
        projectRoot: URL,
        scan: LocalizationCompareScanResult,
        onDeviceCoordinator: OnDeviceTranslationCoordinator
    ) async {
        isMachineTranslating = true
        defer { isMachineTranslating = false }

        do {
            let rows = try await LocalizationOnDeviceTranslationBatch.translateAll(
                items: items,
                coordinator: onDeviceCoordinator
            )
            let jsonl = try LocalizationOnDeviceTranslationBatch.encodeJSONL(rows: rows)
            let report = try LocalizationCursorWorkflow.applyPastedJSONL(
                text: jsonl,
                projectRoot: projectRoot,
                scanResult: scan,
                selected: selectedMissingEntryIDs
            )
            let detail = report.messages.joined(separator: "\n")
            let summary = "本机翻译已写入 \(report.appendedLineCount) 条；跳过 \(report.skippedLineCount) 行。\n\(detail)"
            await self.scan()
            workflowMessage = summary
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
