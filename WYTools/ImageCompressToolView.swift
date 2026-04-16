//
//  ImageCompressToolView.swift
//  WYTools
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private let storageKeysKey = "tinify_api_keys"
private let storageRememberKey = "tinify_remember_keys"

private enum QueueStatus: String {
    case pending
    case working
    case done
    case fail
    case skipped
}

private struct QueueItem: Identifiable {
    let id = UUID()
    var sourceURL: URL?
    var securityScopedStarted = false
    var displayPath: String
    var byteSize: Int64
    var status: QueueStatus
    var errorMessage: String?
    var inBytes: Int?
    var outBytes: Int?
    var writtenInPlace = false
    var exportURL: URL?
    var suggestedDownloadName: String?
}

private actor WorkIndexQueue {
    private var next = 0
    private let indices: [Int]
    init(_ indices: [Int]) { self.indices = indices }
    func pop() -> Int? {
        guard next < indices.count else { return nil }
        defer { next += 1 }
        return indices[next]
    }
}

@MainActor
@Observable
private final class ImageCompressModel {
    var apiKeyText = ""
    var rememberKeys = false
    var minSizeKb: Double = 500
    var concurrency: Int = 2
    var message = ""
    var messageIsError = false
    var queue: [QueueItem] = []
    var isCompressing = false

    private var compressAbortedAllKeys = false
    /// 用户点击「停止压缩」
    private var compressCancelled = false
    private var compressTask: Task<Void, Never>?

    init() {
        if UserDefaults.standard.bool(forKey: storageRememberKey) {
            rememberKeys = true
            apiKeyText = UserDefaults.standard.string(forKey: storageKeysKey) ?? ""
        }
    }

    func persistKeysIfNeeded() {
        if rememberKeys {
            UserDefaults.standard.set(apiKeyText, forKey: storageKeysKey)
            UserDefaults.standard.set(true, forKey: storageRememberKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKeysKey)
            UserDefaults.standard.set(false, forKey: storageRememberKey)
        }
    }

    func showMessage(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "avif"].contains(ext) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image)
        {
            return true
        }
        return false
    }

    private func minSizeBytes() -> Int {
        max(0, Int(minSizeKb * 1024))
    }

    private func normalizedConcurrency() -> Int {
        min(12, max(1, concurrency))
    }

    private func makeItem(url: URL, displayPath: String, started: Bool) -> QueueItem {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let minB = minSizeBytes()
        if minB > 0 && size < Int64(minB) {
            let kb = Int(minSizeKb)
            return QueueItem(
                sourceURL: url,
                securityScopedStarted: started,
                displayPath: displayPath,
                byteSize: size,
                status: .skipped,
                errorMessage: "文件小于 \(kb) KB，未压缩"
            )
        }
        return QueueItem(
            sourceURL: url,
            securityScopedStarted: started,
            displayPath: displayPath,
            byteSize: size,
            status: .pending,
            errorMessage: nil
        )
    }

    func addImageURLs(_ urls: [URL], replace: Bool) {
        var items: [QueueItem] = []
        for url in urls {
            guard Self.isImageURL(url) else { continue }
            let started = url.startAccessingSecurityScopedResource()
            items.append(makeItem(url: url, displayPath: url.lastPathComponent, started: started))
        }
        if replace {
            clearQueue()
            queue = items
        } else {
            queue.append(contentsOf: items)
        }
        if items.isEmpty {
            showMessage("没有可识别的图片。", error: false)
        } else {
            message = ""
        }
    }

    func addFolderURL(_ root: URL) {
        var items: [QueueItem] = []
        let started = root.startAccessingSecurityScopedResource()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            showMessage("无法读取该文件夹。", error: true)
            return
        }
        for case let fileURL as URL in en {
            guard Self.isImageURL(fileURL) else { continue }
            let rel = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let s = fileURL.startAccessingSecurityScopedResource()
            items.append(makeItem(url: fileURL, displayPath: rel.isEmpty ? fileURL.lastPathComponent : rel, started: s))
        }
        clearQueue()
        queue = items
        if items.isEmpty {
            showMessage("该文件夹内没有可识别的图片。", error: false)
        } else {
            message = ""
        }
    }

    func clearQueue() {
        for item in queue {
            if item.securityScopedStarted, let u = item.sourceURL {
                u.stopAccessingSecurityScopedResource()
            }
        }
        queue.removeAll()
        message = ""
    }

    var hasRunnable: Bool {
        queue.contains { $0.status == .pending || $0.status == .fail }
    }

    var visibleQueue: [QueueItem] {
        queue.filter { $0.status != .skipped }
    }

    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .webP, UTType(filenameExtension: "avif") ?? .image]
        if panel.runModal() == .OK {
            addImageURLs(panel.urls, replace: false)
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            addFolderURL(url)
        }
    }

    /// 由界面「开始压缩」调用：在独立 `Task` 中跑会话，便于取消。
    func beginCompressRun() {
        guard !isCompressing else { return }
        let keys = TinifyClient.parseAPIKeys(from: apiKeyText)
        if keys.isEmpty {
            showMessage("请至少填写一个 API Key（每行一个或用逗号分隔）。", error: true)
            return
        }
        compressCancelled = false
        compressTask = Task { @MainActor [weak self] in
            await self?.startCompress()
        }
    }

    /// 由界面「停止压缩」调用。
    func stopCompressRun() {
        guard isCompressing else { return }
        compressCancelled = true
        compressTask?.cancel()
    }

    private func startCompress() async {
        let keys = TinifyClient.parseAPIKeys(from: apiKeyText)
        if keys.isEmpty {
            showMessage("请至少填写一个 API Key（每行一个或用逗号分隔）。", error: true)
            return
        }

        isCompressing = true
        defer {
            isCompressing = false
            compressTask = nil
        }

        compressAbortedAllKeys = false
        showMessage("", error: false)

        for i in queue.indices where queue[i].status == .fail {
            queue[i].status = .pending
            queue[i].errorMessage = nil
        }
        for i in queue.indices where queue[i].status == .pending {
            queue[i].errorMessage = nil
        }

        let minB = minSizeBytes()
        let kbLabel = Int(minSizeKb)
        for i in queue.indices where queue[i].status == .pending {
            if minB > 0 && queue[i].byteSize < Int64(minB) {
                queue[i].status = .skipped
                queue[i].errorMessage = "文件小于 \(kbLabel) KB，未压缩"
            }
        }

        let workIndices = queue.indices.filter { queue[$0].status == .pending }
        if workIndices.isEmpty {
            let skipped = queue.filter { $0.status == .skipped }.count
            showMessage(
                skipped > 0 ? "当前没有待压缩任务（均已跳过或已完成）。" : "没有待压缩任务。",
                error: false
            )
            return
        }

        let n = min(normalizedConcurrency(), workIndices.count)
        let indexQueue = WorkIndexQueue(Array(workIndices))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask { [weak self] in
                    guard let self else { return }
                    while true {
                        if Task.isCancelled { break }
                        if await self.compressUserCancelledSnapshot() { break }
                        let idx = await indexQueue.pop()
                        guard let idx else { break }
                        if await self.compressAbortedAllKeysSnapshot() { break }
                        if await self.compressUserCancelledSnapshot() { break }
                        await self.compressOne(keys: keys, index: idx)
                    }
                }
            }
        }

        for i in queue.indices where queue[i].status == .working {
            queue[i].status = .pending
            queue[i].errorMessage = nil
        }

        if compressCancelled {
            compressCancelled = false
            showMessage("已停止压缩。", error: false)
            return
        }

        let failed = queue.filter { $0.status == .fail }.count
        let ok = queue.filter { $0.status == .done }.count
        let skipped = queue.filter { $0.status == .skipped }.count
        let stillPending = queue.filter { $0.status == .pending }.count

        if compressAbortedAllKeys {
            showMessage(
                "所有 API Key 已达到限制，任务已暂停。"
                    + (stillPending > 0 ? " 仍有 \(stillPending) 项待处理，更新 Key 后请再次点击「开始压缩」。" : ""),
                error: true
            )
        } else if failed > 0 && ok > 0 {
            showMessage("部分完成：成功 \(ok)，失败 \(failed)。", error: true)
        } else if failed > 0 {
            showMessage("全部或部分失败，请查看列表中的错误信息；更新 Key 或排除错误后可再次点击「开始压缩」重试失败项。", error: true)
        } else if ok > 0 {
            var t = "全部完成（本月额度以 Tinify 控制台为准）。"
            if skipped > 0 { t += " 已跳过 \(skipped) 个未达体积阈值的文件。" }
            showMessage(t, error: false)
        }
    }

    private func compressAbortedAllKeysSnapshot() async -> Bool {
        await MainActor.run { compressAbortedAllKeys }
    }

    private func compressUserCancelledSnapshot() async -> Bool {
        await MainActor.run { compressCancelled }
    }

    private func compressOne(keys: [String], index: Int) async {
        if compressAbortedAllKeys { return }
        if await compressUserCancelledSnapshot() { return }
        if queue[index].status == .done || queue[index].status == .skipped { return }

        queue[index].status = .working
        queue[index].errorMessage = nil

        if await compressUserCancelledSnapshot() {
            queue[index].status = .pending
            return
        }

        guard let url = queue[index].sourceURL else {
            queue[index].status = .fail
            queue[index].errorMessage = "缺少文件地址"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            if await compressUserCancelledSnapshot() {
                queue[index].status = .pending
                return
            }
            let name = url.lastPathComponent
            let result = try await TinifyClient.compress(imageData: data, filename: name, apiKeys: keys)

            if await compressUserCancelledSnapshot() {
                queue[index].status = .pending
                return
            }

            var wroteInPlace = false
            if queue[index].securityScopedStarted {
                do {
                    try result.outputData.write(to: url, options: .atomic)
                    wroteInPlace = true
                } catch {
                    wroteInPlace = false
                }
            }

            queue[index].status = .done
            queue[index].inBytes = result.inBytes
            queue[index].outBytes = result.outBytes
            queue[index].writtenInPlace = wroteInPlace
            queue[index].errorMessage = nil
            queue[index].suggestedDownloadName = result.suggestedDownloadName

            if !wroteInPlace {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + result.suggestedDownloadName)
                try result.outputData.write(to: tmp, options: .atomic)
                queue[index].exportURL = tmp
            } else {
                queue[index].exportURL = nil
            }

            if wroteInPlace, let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                queue[index].byteSize = Int64(sz)
            }
        } catch is CancellationError {
            queue[index].status = .pending
            queue[index].errorMessage = nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            queue[index].status = .pending
            queue[index].errorMessage = nil
        } catch TinifyClientError.allKeysExhausted {
            queue[index].status = .pending
            queue[index].errorMessage =
                "当前列表中所有 API Key 已达到次数或限流；请更新 Key 后再次点击「开始压缩」以继续（将重试失败与待处理项）。"
            compressAbortedAllKeys = true
        } catch {
            if await compressUserCancelledSnapshot() {
                queue[index].status = .pending
                queue[index].errorMessage = nil
                return
            }
            queue[index].status = .fail
            queue[index].errorMessage = error.localizedDescription
        }
    }
}

private func formatBytes(_ n: Int64) -> String {
    if n < 1024 { return "\(n) B" }
    if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
    return String(format: "%.2f MB", Double(n) / 1024 / 1024)
}

struct ImageCompressToolView: View {
    @State private var model = ImageCompressModel()
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("使用与 TinyPNG 相同的官方压缩服务（Tinify）。在 tinypng.com/developers 免费注册并获取 API Key。")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.callout)
                        .foregroundStyle(model.messageIsError ? DiffToolTheme.error : DiffToolTheme.ok)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.messageIsError ? DiffToolTheme.error.opacity(0.12) : DiffToolTheme.ok.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(model.messageIsError ? DiffToolTheme.error.opacity(0.35) : DiffToolTheme.ok.opacity(0.3))
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("API KEY 列表（从上到下依次使用；每行一个，也可用英文逗号分隔）")
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.muted)
                    TextEditor(text: $model.apiKeyText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(DiffToolTheme.text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffToolTheme.border))
                        .onChange(of: model.apiKeyText) { _, _ in
                            model.persistKeysIfNeeded()
                        }
                    Toggle("记住 Key（保存到本地）", isOn: $model.rememberKeys)
                        .tint(DiffToolTheme.accent)
                        .foregroundStyle(DiffToolTheme.text)
                        .onChange(of: model.rememberKeys) { _, v in
                            if !v {
                                UserDefaults.standard.removeObject(forKey: storageKeysKey)
                                UserDefaults.standard.set(false, forKey: storageRememberKey)
                            } else {
                                model.persistKeysIfNeeded()
                            }
                        }
                }

                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最小体积（KB）")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        TextField("", value: $model.minSizeKb, format: .number)
                            .textFieldStyle(.plain)
                            .foregroundStyle(DiffToolTheme.text)
                            .padding(8)
                            .frame(width: 116)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffToolTheme.border))
                        Text("0 表示不限制；小于该值的文件加入列表但标记为已跳过，不调用 API。")
                            .font(.caption2)
                            .foregroundStyle(DiffToolTheme.muted.opacity(0.85))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("并发任务数")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        Stepper(value: $model.concurrency, in: 1...12) {
                            Text("\(model.concurrency)")
                                .monospacedDigit()
                                .foregroundStyle(DiffToolTheme.text)
                                .frame(minWidth: 24, alignment: .leading)
                        }
                        .tint(DiffToolTheme.accent)
                        Text("建议 1～4；多 Key 轮换时仍不宜过大。")
                            .font(.caption2)
                            .foregroundStyle(DiffToolTheme.muted.opacity(0.85))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("添加图片")
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.muted)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundStyle(dropTargeted ? DiffToolTheme.accent : DiffToolTheme.border)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DiffToolTheme.surface)
                        )
                        .frame(minHeight: 120)
                        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                            handleFileDrop(providers: providers)
                        }
                        .overlay {
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    Button("选择图片（可多选）") { model.pickImages() }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(DiffToolTheme.accent)
                                        .fontWeight(.semibold)
                                    Text("·")
                                        .foregroundStyle(DiffToolTheme.muted)
                                    Button("选择文件夹（递归）") { model.pickFolder() }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(DiffToolTheme.accent)
                                        .fontWeight(.semibold)
                                }
                                Text("JPEG、PNG、WebP、AVIF。若对所选文件具备写权限，将尝试覆盖原文件；否则压缩结果导出到临时文件并可另存。")
                                    .font(.caption)
                                    .foregroundStyle(DiffToolTheme.muted)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                            }
                        }
                }

                HStack {
                    if model.isCompressing {
                        Button("停止压缩") {
                            model.stopCompressRun()
                        }
                        .buttonStyle(DiffToolSecondaryButtonStyle())
                    } else {
                        Button("开始压缩") {
                            model.beginCompressRun()
                        }
                        .buttonStyle(DiffToolPrimaryButtonStyle())
                        .disabled(!model.hasRunnable)
                        .opacity(model.hasRunnable ? 1 : 0.45)
                    }
                    Button("清空列表") { model.clearQueue() }
                        .buttonStyle(DiffToolSecondaryButtonStyle())
                        .disabled(model.isCompressing)
                        .opacity(model.isCompressing ? 0.45 : 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.visibleQueue) { item in
                        compressRow(item)
                    }
                }
            }
            .padding(20)
        }
        .background(DiffToolTheme.background)
        .navigationTitle("图片压缩（Tinify）")
        .toolbarBackground(DiffToolTheme.background, for: .automatic)
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                do {
                    let item = try await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                    if let url = item as? URL {
                        urls.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                } catch {
                    continue
                }
            }
            await MainActor.run {
                if urls.count == 1, let u = urls.first {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                        model.addFolderURL(u)
                        return
                    }
                }
                model.addImageURLs(urls, replace: false)
            }
        }
        return true
    }

    @ViewBuilder
    private func compressRow(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayPath)
                    .font(.callout)
                    .foregroundStyle(DiffToolTheme.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                statusBadge(item.status)
            }
            HStack {
                Text(metaLine(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DiffToolTheme.muted)
                Spacer()
                if let export = item.exportURL {
                    Button("另存为…") {
                        saveExport(source: export, suggestedName: item.suggestedDownloadName ?? item.displayPath)
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                }
            }
            if let err = item.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(item.status == .skipped ? DiffToolTheme.muted : DiffToolTheme.error)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DiffToolTheme.border))
    }

    private func metaLine(_ item: QueueItem) -> String {
        if let a = item.inBytes, let b = item.outBytes {
            let pct = a > 0 ? Int(round((1 - Double(b) / Double(a)) * 100)) : 0
            var s = "\(formatBytes(Int64(a))) → \(formatBytes(Int64(b)))（约减 \(pct)%）"
            if item.writtenInPlace { s += " · 已覆盖原文件" }
            return s
        }
        return formatBytes(item.byteSize)
    }

    @ViewBuilder
    private func statusBadge(_ s: QueueStatus) -> some View {
        let text: String = switch s {
        case .pending: "待处理"
        case .working: "压缩中…"
        case .done: "完成"
        case .fail: "失败"
        case .skipped: "已跳过"
        }
        let color: Color = switch s {
        case .pending, .working: DiffToolTheme.muted
        case .done: DiffToolTheme.bothGreen
        case .fail: DiffToolTheme.error
        case .skipped: DiffToolTheme.muted
        }
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private func saveExport(source: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let base = (suggestedName as NSString).deletingPathExtension
        panel.nameFieldStringValue = base.isEmpty ? "image-tiny.\(ext)" : "\(base).\(ext)"
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: source, to: dest)
        }
    }
}
