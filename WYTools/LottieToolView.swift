//
//  LottieToolView.swift
//  WYTools
//
//  参考 https://www.bejson.com/ui/lottie/ ：拖入 json / lottie 预览、播放暂停、跳帧、背景色、导出 PNG。
//

import AppKit
import Lottie
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件元信息（展示用）

private struct LottieFileInfo: Equatable {
    var widthPx: Int?
    var heightPx: Int?
    var framerate: Double
    var totalFrames: Int
    var schemaVersion: String?
    var fileSizeBytes: Int64?
}

private func intFromJSONNumber(_ any: Any?) -> Int? {
    switch any {
    case let i as Int: return i
    case let n as NSNumber: return n.intValue
    case let d as Double: return Int(d)
    default: return nil
    }
}

/// `LottieAnimation` 公共 API 不含 w/h/v，通过 Codable 编码结果读取顶层字段。
private func canvasAndVersion(from animation: LottieAnimation) -> (w: Int?, h: Int?, v: String?) {
    guard let data = try? JSONEncoder().encode(animation),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return (nil, nil, nil)
    }
    let w = intFromJSONNumber(obj["w"])
    let h = intFromJSONNumber(obj["h"])
    let v = obj["v"] as? String
    return (w, h, v)
}

private func fileByteSize(atPath path: String) -> Int64? {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value
}

private func formatFileSize(_ bytes: Int64) -> String {
    let kb = Double(bytes) / 1024.0
    if kb < 1024 { return String(format: "%.2f KB", kb) }
    let mb = kb / 1024.0
    if mb < 1024 { return String(format: "%.2f MB", mb) }
    let gb = mb / 1024.0
    return String(format: "%.2f GB", gb)
}

private func totalFrameCount(start: CGFloat, end: CGFloat) -> Int {
    max(0, Int(round(abs(Double(end) - Double(start)))))
}

private let demoLottieJSON = """
{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":200,"h":200,"nm":"Demo","ddd":0,"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"Ellipse","sr":1,"ks":{"o":{"a":0,"k":100},"r":{"a":1,"k":[{"i":{"x":[0.833],"y":[0.833]},"o":{"x":[0.167],"y":[0.167]},"t":0,"s":[0]},{"t":60,"s":[360]}]},"p":{"a":0,"k":[100,100,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,"ip":0,"op":60,"st":0,"bm":0,"shapes":[{"ty":"gr","it":[{"ty":"el","s":{"a":0,"k":[72,72]},"p":{"a":0,"k":[0,0]},"nm":"Ellipse Path"},{"ty":"fl","c":{"a":0,"k":[0.35,0.45,0.95,1]},"o":{"a":0,"k":100},"r":1,"nm":"Fill"}],"nm":"Ellipse","np":3,"cix":2,"bm":0,"ix":1}]}]}
"""

// MARK: - AppKit host

private final class LottieHostView: NSView {
    private var player: LottieAnimationView?
    /// 丢弃过期的 .lottie 异步回调，避免快速换文件时写错状态。
    private var loadNonce: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 让 Lottie 视图始终占满宿主 bounds；实际的 aspect-fit 由 Lottie 的 `contentMode` 完成。
    override func layout() {
        super.layout()
        player?.frame = bounds
    }

    private func configurePlayer(_ v: LottieAnimationView) {
        v.loopMode = .loop
        v.contentMode = .scaleAspectFit
        v.maskAnimationToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoresizingMask = [.width, .height]
        v.frame = bounds
    }

    func clear() {
        loadNonce &+= 1
        player?.removeFromSuperview()
        player = nil
    }

    func loadJSON(path: String, onLoaded: @escaping (LottieAnimation) -> Void, onError: @escaping (String) -> Void) {
        clear()
        let v = LottieAnimationView(filePath: path)
        configurePlayer(v)
        addSubview(v)
        player = v
        needsLayout = true
        if let anim = v.animation {
            onLoaded(anim)
            v.play()
        } else {
            onError("无法解析 Lottie JSON")
        }
    }

    func loadDotLottie(path: String, onLoaded: @escaping (LottieAnimation) -> Void, onError: @escaping (String) -> Void) {
        clear()
        let nonce = loadNonce
        let v = LottieAnimationView(dotLottieFilePath: path, animationId: nil) { [weak self] view, error in
            DispatchQueue.main.async {
                guard let self, self.loadNonce == nonce else { return }
                if let error {
                    onError(error.localizedDescription)
                    return
                }
                self.configurePlayer(view)
                self.needsLayout = true
                if let anim = view.animation {
                    onLoaded(anim)
                    view.play()
                } else {
                    onError("无法从 .lottie 中读取动画")
                }
            }
        }
        configurePlayer(v)
        addSubview(v)
        player = v
        needsLayout = true
    }

    var lottieView: LottieAnimationView? { player }

    func setCanvasBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }
}

private func exportPNG(from view: LottieAnimationView) {
    guard view.bounds.width > 1, view.bounds.height > 1 else { return }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let img = NSImage(size: view.bounds.size)
    img.addRepresentation(rep)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "lottie-frame.png"
    if panel.runModal() == .OK, let dest = panel.url,
       let tiff = img.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:])
    {
        try? png.write(to: dest)
    }
}

private struct LottieHostRepresentable: NSViewRepresentable {
    let filePath: String
    let isDotLottie: Bool
    let canvasBackground: NSColor
    @Binding var isPlaying: Bool
    @Binding var scrubFrame: Double
    @Binding var exportPNGTicket: Int
    let onLoaded: (LottieAnimation) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LottieHostView {
        let v = LottieHostView()
        context.coordinator.host = v
        context.coordinator.lastPath = nil
        context.coordinator.lastExportTicket = 0
        return v
    }

    func updateNSView(_ nsView: LottieHostView, context: Context) {
        nsView.setCanvasBackground(canvasBackground)

        if context.coordinator.lastPath != filePath {
            context.coordinator.lastPath = filePath
            if isDotLottie {
                nsView.loadDotLottie(path: filePath, onLoaded: onLoaded, onError: onError)
            } else {
                nsView.loadJSON(path: filePath, onLoaded: onLoaded, onError: onError)
            }
        }

        guard let lv = nsView.lottieView else { return }

        if isPlaying {
            if !lv.isAnimationPlaying {
                lv.play()
            }
        } else {
            lv.pause()
            lv.currentFrame = AnimationFrameTime(scrubFrame)
        }

        if exportPNGTicket != context.coordinator.lastExportTicket, exportPNGTicket > 0 {
            context.coordinator.lastExportTicket = exportPNGTicket
            exportPNG(from: lv)
        }
    }

    final class Coordinator {
        weak var host: LottieHostView?
        var lastPath: String?
        var lastExportTicket: Int = 0
    }
}

// MARK: - Model

@MainActor
@Observable
private final class LottieToolModel {
    var filePath: String?
    var isDotLottie = false
    var securityScoped = false
    var isPlaying = true
    var canvasColor: Color = Color(DiffToolTheme.background)
    var startFrame: CGFloat = 0
    var endFrame: CGFloat = 120
    var scrubFrame: Double = 0
    var exportPNGTicket = 0
    var hint = "将 lottie.json 或 .lottie 文件拖入下方区域，或点击「来个 DEMO」。"
    var errorMessage: String?
    var fileInfo: LottieFileInfo?

    var hasFile: Bool { filePath != nil }

    func releaseSecurityScope() {
        if securityScoped, let p = filePath {
            URL(fileURLWithPath: p).stopAccessingSecurityScopedResource()
        }
        securityScoped = false
    }

    func clearFile() {
        releaseSecurityScope()
        filePath = nil
        isDotLottie = false
        errorMessage = nil
        isPlaying = true
        exportPNGTicket = 0
        fileInfo = nil
    }

    func loadURL(_ url: URL) {
        clearFile()
        let started = url.startAccessingSecurityScopedResource()
        securityScoped = started
        let ext = url.pathExtension.lowercased()
        guard ext == "json" || ext == "lottie" else {
            errorMessage = "仅支持 .json（Bodymovin）或 .lottie 文件。"
            if started { url.stopAccessingSecurityScopedResource() }
            securityScoped = false
            return
        }
        filePath = url.path
        isDotLottie = (ext == "lottie")
        errorMessage = nil
        isPlaying = true
        hint = url.lastPathComponent
        fileInfo = nil
    }

    func loadDemo() {
        clearFile()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("WYTools-lottie-demo-\(UUID().uuidString).json")
        do {
            try Data(demoLottieJSON.utf8).write(to: tmp)
            filePath = tmp.path
            isDotLottie = false
            securityScoped = false
            errorMessage = nil
            isPlaying = true
            hint = "内置 DEMO（旋转圆形）"
            fileInfo = nil
        } catch {
            errorMessage = "无法写入临时文件：\(error.localizedDescription)"
        }
    }

    func jumpToFrameField(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Double(t) else { return }
        isPlaying = false
        let lo = Double(min(startFrame, endFrame))
        let hi = Double(max(startFrame, endFrame))
        scrubFrame = min(hi, max(lo, v))
    }

    func requestExportPNG() {
        exportPNGTicket &+= 1
    }

    func applyLoadedAnimation(_ animation: LottieAnimation) {
        let start = animation.startFrame
        let end = animation.endFrame
        startFrame = start
        endFrame = end
        scrubFrame = Double(start)
        let (w, h, v) = canvasAndVersion(from: animation)
        let bytes = filePath.flatMap { fileByteSize(atPath: $0) }
        fileInfo = LottieFileInfo(
            widthPx: w,
            heightPx: h,
            framerate: animation.framerate,
            totalFrames: totalFrameCount(start: start, end: end),
            schemaVersion: v,
            fileSizeBytes: bytes
        )
        errorMessage = nil
    }
}

// MARK: - View

struct LottieToolView: View {
    private let infoWidth: CGFloat = 248
    /// 外层拖放命中区（固定）。
    private let previewSlotSide: CGFloat = 800
    /// 实际 Lottie 渲染视图略小，留出边距，配合 aspectFit 减少「画不满 / 被裁切」观感。
    private let lottiePlaybackSide: CGFloat = 560

    @State private var model = LottieToolModel()
    @State private var frameFieldText = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                Text(model.hint)
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)
                    .lineLimit(1)

                if let err = model.errorMessage {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(DiffToolTheme.error)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.error.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffToolTheme.error.opacity(0.35)))
                }

                HStack(spacing: 8) {
                    Group {
                        if model.isPlaying {
                            Button("暂停") {
                                model.isPlaying = false
                            }
                            .buttonStyle(DiffToolSecondaryButtonStyle())
                        } else {
                            Button("播放") {
                                model.isPlaying = true
                            }
                            .buttonStyle(DiffToolPrimaryButtonStyle())
                        }
                    }

                    Button("来个 DEMO") {
                        model.loadDemo()
                        frameFieldText = ""
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())

                    if model.hasFile {
                        Button("清除") {
                            model.clearFile()
                            frameFieldText = ""
                        }
                        .buttonStyle(DiffToolSecondaryButtonStyle())
                    }

                    Text("跳至帧")
                        .foregroundStyle(DiffToolTheme.muted)
                    TextField("帧号", text: $frameFieldText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(DiffToolTheme.text)
                        .padding(6)
                        .frame(width: 88)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DiffToolTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DiffToolTheme.border))
                    Button("跳转") {
                        model.jumpToFrameField(frameFieldText)
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("帧进度（暂停时可拖动）")
                        .font(.caption2)
                        .foregroundStyle(DiffToolTheme.muted)
                    Slider(
                        value: $model.scrubFrame,
                        in: Double(min(model.startFrame, model.endFrame)) ... Double(max(model.startFrame, model.endFrame)),
                        onEditingChanged: { editing in
                            if editing { model.isPlaying = false }
                        }
                    )
                    .tint(DiffToolTheme.accent)
                    .controlSize(.small)
                    .disabled(!model.hasFile)
                }
            }
            .zIndex(2)

            HStack(alignment: .top, spacing: 14) {
                previewSlot
                    .zIndex(0)

                lottieInfoPanel
                    .frame(width: infoWidth, alignment: .topLeading)
                    .zIndex(0)
            }

            Group {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("背景色")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        ColorPicker("", selection: $model.canvasColor, supportsOpacity: true)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                    Button("保存为 PNG（当前帧）") {
                        model.isPlaying = false
                        model.requestExportPNG()
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(!model.hasFile)

                    Text("SVG 导出未集成。")
                        .font(.caption2)
                        .foregroundStyle(DiffToolTheme.muted.opacity(0.85))

                    Spacer(minLength: 0)
                }

                Text("说明：本地解析与渲染，不上传；外部图片需 base64 内嵌。")
                    .font(.caption2)
                    .foregroundStyle(DiffToolTheme.muted.opacity(0.85))
                    .lineLimit(2)
            }
            .zIndex(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DiffToolTheme.background)
        .navigationTitle("Lottie 预览")
        .toolbarBackground(DiffToolTheme.background, for: .automatic)
    }

    private var lottieInfoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("基本信息")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DiffToolTheme.text)

            if let info = model.fileInfo {
                lottieInfoRow(title: "宽度", value: info.widthPx.map { "\($0) px" } ?? "—")
                lottieInfoRow(title: "高度", value: info.heightPx.map { "\($0) px" } ?? "—")
                lottieInfoRow(title: "帧率", value: String(format: "%.2f 帧/秒", info.framerate))
                lottieInfoRow(title: "总帧数", value: "\(info.totalFrames) 帧")
                lottieInfoRow(title: "版本", value: info.schemaVersion ?? "—")
                lottieInfoRow(title: "文件大小", value: info.fileSizeBytes.map { formatFileSize($0) } ?? "—")
            } else {
                Text("加载动画后将显示尺寸、帧率、帧数、版本与文件大小。")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DiffToolTheme.border.opacity(0.55)))
    }

    private func lottieInfoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title + "：")
                .font(.subheadline)
                .foregroundStyle(DiffToolTheme.muted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(DiffToolTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 空状态占位；拖放由外层 `previewSlot` 统一处理，播放中也可拖入新文件替换。
    private var dropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(dropTargeted ? DiffToolTheme.accent : DiffToolTheme.border)
            .background(RoundedRectangle(cornerRadius: 12).fill(DiffToolTheme.surface))
            .overlay {
                VStack(spacing: 8) {
                    Text("拖入 lottie.json 或 .lottie")
                        .font(.headline)
                        .foregroundStyle(DiffToolTheme.text)
                    Text("松手后自动加载并播放")
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewSlot: some View {
        ZStack {
            Rectangle()
                .fill(model.canvasColor)
                .allowsHitTesting(false)

            if model.hasFile, let path = model.filePath {
                LottieHostRepresentable(
                    filePath: path,
                    isDotLottie: model.isDotLottie,
                    canvasBackground: NSColor(model.canvasColor),
                    isPlaying: $model.isPlaying,
                    scrubFrame: $model.scrubFrame,
                    exportPNGTicket: $model.exportPNGTicket,
                    onLoaded: { anim in
                        model.applyLoadedAnimation(anim)
                    },
                    onError: { msg in
                        model.errorMessage = msg
                        model.fileInfo = nil
                    }
                )
                .id(path)
                .frame(width: lottiePlaybackSide, height: lottiePlaybackSide)
            } else {
                dropPlaceholder
            }
        }
        .frame(width: previewSlotSide, height: previewSlotSide)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted ? DiffToolTheme.accent : DiffToolTheme.border.opacity(0.6), lineWidth: dropTargeted ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task {
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                do {
                    let item = try await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                    let url: URL? = (item as? URL) ?? ((item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    if let url {
                        await MainActor.run {
                            model.loadURL(url)
                            frameFieldText = ""
                        }
                        return
                    }
                } catch {
                    continue
                }
            }
        }
        return true
    }
}
