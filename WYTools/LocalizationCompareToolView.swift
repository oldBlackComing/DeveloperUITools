//
//  LocalizationCompareToolView.swift
//  WYTools
//

import AppKit
import SwiftUI

struct LocalizationCompareToolView: View {
    @State private var viewModel = LocalizationCompareViewModel()
    @State private var onDeviceTranslationCoordinator = OnDeviceTranslationCoordinator()

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "每个语言标签下列出：英文 `.strings` 里已有、但该语言 `.strings` 里缺失的 key。仅扫描 `Pods/` 以外的文件（主工程及本地模块，如 CMPurchaseIOS）。若工程内没有英文 `.strings`，则退而使用 String Catalog（`.xcstrings`）。"
                )
                .font(.subheadline)
                .foregroundStyle(DiffToolTheme.muted)

                HStack(spacing: 12) {
                    Button("选择文件夹…") {
                        viewModel.pickProjectFolder()
                    }
                    .buttonStyle(DiffToolPrimaryButtonStyle())

                    Button("扫描") {
                        Task { await viewModel.scan() }
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    .disabled(viewModel.selectedFolderPath.isEmpty || viewModel.isScanning)

                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .tint(DiffToolTheme.accent)
                .foregroundStyle(DiffToolTheme.text)

                if !viewModel.selectedFolderPath.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已选路径")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        Text(viewModel.selectedFolderPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DiffToolTheme.text)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(DiffToolTheme.border)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key 对比追踪（调试）")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        TextField("输入要追踪的 key", text: $viewModel.debugTraceKey)
                            .textFieldStyle(.roundedBorder)
                        Button("打印对比过程") {
                            Task { await viewModel.runKeyTrace() }
                        }
                        .buttonStyle(DiffToolSecondaryButtonStyle())
                        .disabled(viewModel.isTracingKey || viewModel.isScanning)
                        if viewModel.isTracingKey {
                            ProgressView().controlSize(.small)
                        }
                        if !viewModel.debugTraceOutput.isEmpty {
                            ScrollView {
                                Text(viewModel.debugTraceOutput)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(DiffToolTheme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 280)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(DiffToolTheme.border)
                    )
                }

                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(DiffToolTheme.error)
                }

                if let result = viewModel.scanResult {
                    summarySection(result)

                    machineTranslationBar(viewModel: viewModel)

                    localizationWorkflowBar(viewModel: viewModel)

                    if !result.languages.isEmpty {
                        localeTabsAndMissingList(result: result, viewModel: viewModel)
                    } else {
                        Text("未发现非英文 `.strings` / String Catalog 条目，或各语言与英文 key 集合一致。")
                            .font(.subheadline)
                            .foregroundStyle(DiffToolTheme.muted)
                    }
                }
            }
            .padding(20)
        }
        .background(DiffToolTheme.background)
        .navigationTitle(localizationNavigationTitle(viewModel: viewModel))
        .toolbarBackground(DiffToolTheme.background, for: .automatic)
        .background {
            if #available(macOS 15.0, *) {
                OnDeviceTranslationRunner(coordinator: onDeviceTranslationCoordinator)
            }
        }
        .sheet(isPresented: $viewModel.showAppendTranslationSheet) {
            appendTranslationSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.cursorGuidePayload) { payload in
            cursorLocalizationGuideSheet(payload: payload, viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showTranslationLanguageDownloadSheet) {
            translationLanguageDownloadSheet(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func machineTranslationBar(viewModel: LocalizationCompareViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机翻译（Apple Translation）")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            Text(
                "使用系统自带的离线翻译模型（macOS 15+）。若尚未下载对应语言包，会弹出窗口，点「帮我下载」即可触发系统下载；也可在「系统设置 → 通用 → 语言与地区 → 翻译语言」中管理。"
            )
            .font(.caption2)
            .foregroundStyle(DiffToolTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("本机翻译（生成右侧结果）") {
                    Task {
                        await viewModel.machineTranslateSelectedToPreview(onDeviceCoordinator: onDeviceTranslationCoordinator)
                    }
                }
                .buttonStyle(DiffToolPrimaryButtonStyle())
                .disabled(viewModel.isMachineTranslating || viewModel.isScanning)

                Button("应用（写入工程）") {
                    Task { await viewModel.applyTranslatedPreviewToFiles() }
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
                .disabled(viewModel.isMachineTranslating || viewModel.isScanning)

                if viewModel.isMachineTranslating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DiffToolTheme.border)
        )
    }

    @ViewBuilder
    private func translationLanguageDownloadSheet(viewModel: LocalizationCompareViewModel) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("以下语言的翻译模型尚未下载到本机，无法从英文翻译到对应语言：")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.text)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.translationLocalesNeedingDownload, id: \.self) { code in
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DiffToolTheme.text)
                    }
                }
                Text("点击下方按钮后，系统将请求下载（可能出现系统权限或进度界面）。")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
                Button("帮我下载") {
                    Task {
                        await viewModel.downloadTranslationLanguagePacksAndTranslate(
                            onDeviceCoordinator: onDeviceTranslationCoordinator
                        )
                    }
                }
                .buttonStyle(DiffToolPrimaryButtonStyle())
                .disabled(viewModel.isMachineTranslating)

                Button("取消（本次不再提示）") {
                    viewModel.cancelTranslationLanguageDownload()
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
                .disabled(viewModel.isMachineTranslating)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 420, minHeight: 280, alignment: .topLeading)
            .background(DiffToolTheme.background)
            .navigationTitle("下载翻译语言包")
            .toolbarBackground(DiffToolTheme.background, for: .automatic)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        viewModel.cancelTranslationLanguageDownload()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func localizationWorkflowBar(viewModel: LocalizationCompareViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CURSOR / 写入")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            Text("分两步：① 在 Cursor 里按提示生成 JSONL；② 回到本应用写入工程。点第 1 步后会自动弹出说明窗口。")
                .font(.caption2)
                .foregroundStyle(DiffToolTheme.muted)
            HStack(spacing: 10) {
                Button("第 1 步：打开 Cursor 并翻译勾选") {
                    viewModel.invokeCursorForSelectedTranslations()
                }
                .buttonStyle(DiffToolPrimaryButtonStyle())

                Button("第 2 步：从剪贴板写入工程") {
                    viewModel.pasteAppendTextFromClipboard()
                    viewModel.applyAppendFromPastedJSONL()
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())

                Button("手动粘贴后写入…") {
                    viewModel.showAppendTranslationSheet = true
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
            }
            if let msg = viewModel.workflowMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DiffToolTheme.border)
        )
    }

    @ViewBuilder
    private func cursorLocalizationGuideSheet(
        payload: CursorLocalizationGuidePayload,
        viewModel: LocalizationCompareViewModel
    ) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(payload.launchSummary)
                        .font(.subheadline)
                        .foregroundStyle(DiffToolTheme.text)
                        .textSelection(.enabled)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("在 Cursor 里")
                            .font(.headline)
                            .foregroundStyle(DiffToolTheme.text)
                        guideStepRow(number: 1, text: "应已打开本任务的 Markdown；若未打开，可用下方「复制路径」在 Finder 中打开，或把剪贴板全文粘贴到新文件。")
                        guideStepRow(number: 2, text: "按 Cmd+L（或 Composer），输入 @ 并选中该 `.md` 文件，把整份说明交给模型。")
                        guideStepRow(number: 3, text: "点下面「复制发给 Cursor 的口令」，回到 Cursor 粘贴并发送；或手动输入文件中灰色框内的同一句话。")
                        guideStepRow(number: 4, text: "等回复出现后，只复制其中的 JSON 行（每行以 { 开头、} 结尾），不要复制 markdown 围栏或解释文字。")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("回到 WYTools")
                            .font(.headline)
                            .foregroundStyle(DiffToolTheme.text)
                        guideStepRow(number: 5, text: "点「从剪贴板读取并写入工程」。若要先删改 AI 输出，用「手动粘贴后写入」。")
                        guideStepRow(number: 6, text: "写入前请勿取消勾选本次要写入的条目；locale/key 须与列表一致。")
                    }

                    if let path = payload.tempFilePath {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("提示文件路径")
                                .font(.caption)
                                .foregroundStyle(DiffToolTheme.muted)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(DiffToolTheme.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffToolTheme.border))
                            HStack(spacing: 10) {
                                Button("复制路径") {
                                    viewModel.copyTempPromptPathToPasteboard(path)
                                }
                                .buttonStyle(DiffToolSecondaryButtonStyle())
                                Button("在 Finder 中显示") {
                                    let url = URL(fileURLWithPath: path)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                .buttonStyle(DiffToolSecondaryButtonStyle())
                            }
                        }
                    }

                    Button("复制发给 Cursor 的口令") {
                        viewModel.copyCursorChatOneLinerToPasteboard()
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())

                    Button("从剪贴板读取并写入工程") {
                        viewModel.applyAppendFromClipboardThroughGuide()
                    }
                    .buttonStyle(DiffToolPrimaryButtonStyle())

                    Button("手动粘贴后写入…") {
                        viewModel.openManualAppendSheetFromGuide()
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DiffToolTheme.background)
            .navigationTitle("接下来怎么做")
            .toolbarBackground(DiffToolTheme.background, for: .automatic)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        viewModel.cursorGuidePayload = nil
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private func guideStepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DiffToolTheme.accent)
                .frame(width: 22, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DiffToolTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func appendTranslationSheet(viewModel: LocalizationCompareViewModel) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("将 Cursor 输出的 **JSONL** 粘贴到下方（每行一个 JSON 对象，不要代码围栏）。若刚点过「第 1 步」，也可在自动弹出的引导里一键写入。")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.text)
                Text(#"{"locale":"zh-Hans","key":"…","value":"…"}"#)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DiffToolTheme.muted)
                TextEditor(text: $viewModel.appendPasteText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(DiffToolTheme.text)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffToolTheme.border))
                HStack(spacing: 10) {
                    Button("从剪贴板粘贴") {
                        viewModel.pasteAppendTextFromClipboard()
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    Spacer()
                    Button("取消") {
                        viewModel.showAppendTranslationSheet = false
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    Button("追加到工程") {
                        viewModel.applyAppendFromPastedJSONL()
                    }
                    .buttonStyle(DiffToolPrimaryButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DiffToolTheme.background)
            .navigationTitle("追加译文到 Localizable.strings")
            .toolbarBackground(DiffToolTheme.background, for: .automatic)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    /// 中文（英文+项目中文件夹/文件名）
    private func localizationNavigationTitle(viewModel: LocalizationCompareViewModel) -> String {
        let zh = "本地化对比"
        let en = "Localization vs EN"
        guard !viewModel.selectedFolderPath.isEmpty else {
            return "\(zh)（\(en)）"
        }
        let name = (viewModel.selectedFolderPath as NSString).lastPathComponent
        return "\(zh)（\(en)+\(name)）"
    }

    @ViewBuilder
    private func summarySection(_ result: LocalizationCompareScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("概要")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            HStack(spacing: 18) {
                Label("英文参考：\(result.englishReferenceDescription)", systemImage: "character.book.closed")
                Label("英文 key 数：\(result.englishKeyCount)", systemImage: "number")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DiffToolTheme.text)

            if result.usedStringsFilesAsReference {
                Text("对比方式：仅以各语言 `.lproj` 中的 `.strings` 为准；参考集与列表均不使用 String Catalog。")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DiffToolTheme.border)
        )
    }

    @ViewBuilder
    private func localeTabsAndMissingList(result: LocalizationCompareScanResult, viewModel: LocalizationCompareViewModel) -> some View {
        let sortedLangs = result.languages.sorted { $0.languageCode.localizedCaseInsensitiveCompare($1.languageCode) == .orderedAscending }

        VStack(alignment: .leading, spacing: 12) {
            Text("语言")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(sortedLangs) { row in
                        let selected = viewModel.selectedLanguageTab == row.languageCode
                        Button {
                            viewModel.selectedLanguageTab = row.languageCode
                        } label: {
                            Text(tabLabel(row))
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? DiffToolTheme.text : DiffToolTheme.muted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        DiffToolTheme.accent.opacity(0.32),
                                                        DiffToolTheme.accent.opacity(0.14),
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(DiffToolTheme.accent.opacity(0.55), lineWidth: 1)
                                            )
                                    } else {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(DiffToolTheme.surface)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(DiffToolTheme.border, lineWidth: 1)
                                            )
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text("当前语言")
                    .font(.caption2)
                    .foregroundStyle(DiffToolTheme.muted)
                Button("全选") { viewModel.selectAllInCurrentTab() }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                Button("全不选") { viewModel.deselectAllInCurrentTab() }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                Text("·")
                    .foregroundStyle(DiffToolTheme.muted)
                Text("全部语言")
                    .font(.caption2)
                    .foregroundStyle(DiffToolTheme.muted)
                Button("全选") { viewModel.selectAllEntries() }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                Button("全不选") { viewModel.deselectAllEntries() }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
            }
            .disabled(viewModel.isScanning)

            if let active = sortedLangs.first(where: { $0.languageCode == viewModel.selectedLanguageTab }) {
                if active.missingEntries.isEmpty {
                    Text("\(active.languageCode)：无缺失 key。")
                        .font(.subheadline)
                        .foregroundStyle(DiffToolTheme.ok)
                        .padding(.vertical, 8)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("缺失项")
                                .font(.caption)
                                .foregroundStyle(DiffToolTheme.muted)
                            ForEach(active.missingEntries) { entry in
                                let id = LocalizationMissingEntryID(languageCode: active.languageCode, key: entry.key)
                                missingEntryRow(entry: entry, id: id, viewModel: viewModel)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("翻译结果（预览）")
                                .font(.caption)
                                .foregroundStyle(DiffToolTheme.muted)
                            ForEach(active.missingEntries) { entry in
                                let id = LocalizationMissingEntryID(languageCode: active.languageCode, key: entry.key)
                                translatedPreviewRow(entry: entry, id: id, viewModel: viewModel)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if !viewModel.selectedLanguageTab.isEmpty {
                Text("当前标签「\(viewModel.selectedLanguageTab)」无对应数据。")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)
            }
        }
    }

    private func tabLabel(_ row: LanguageMissingResult) -> String {
        if row.missingEntries.isEmpty {
            return row.languageCode
        }
        return "\(row.languageCode)（\(row.missingEntries.count)）"
    }

    @ViewBuilder
    private func missingEntryRow(
        entry: MissingLocalizationEntry,
        id: LocalizationMissingEntryID,
        viewModel: LocalizationCompareViewModel
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.selectedMissingEntryIDs.contains(id) },
                    set: { viewModel.setEntrySelected(id, isOn: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.key)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(DiffToolTheme.onlyB)
                    .textSelection(.enabled)
                if !entry.englishValue.isEmpty {
                    Text(entry.englishValue)
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.muted)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DiffToolTheme.border.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func translatedPreviewRow(
        entry: MissingLocalizationEntry,
        id: LocalizationMissingEntryID,
        viewModel: LocalizationCompareViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(DiffToolTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let v = viewModel.translatedPreviewByID[id], !v.isEmpty {
                Text(v)
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("（未生成）")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DiffToolTheme.border.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        LocalizationCompareToolView()
    }
    .frame(minWidth: 700, minHeight: 500)
}
