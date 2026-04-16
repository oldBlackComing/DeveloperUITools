//
//  JSONFormatToolView.swift
//  WYTools
//

import AppKit
import SwiftUI

private enum JSONIndentChoice: String, CaseIterable, Identifiable {
    case two = "2 空格"
    case four = "4 空格"
    case tab = "Tab"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .two: return "  "
        case .four: return "    "
        case .tab: return "\t"
        }
    }
}

private enum JSONHighlight {
    static func attributed(from jsonString: String) -> AttributedString {
        let keyColor = Color(red: 0.49, green: 0.83, blue: 0.99)
        let stringColor = Color(red: 0.53, green: 0.94, blue: 0.67)
        let numberColor = Color(red: 0.99, green: 0.83, blue: 0.36)
        let keywordColor = Color(red: 0.77, green: 0.71, blue: 0.99)
        let punctColor = Color(red: 0.39, green: 0.45, blue: 0.55)
        let plainColor = DiffToolTheme.text

        func piece(_ s: String, _ c: Color) -> AttributedString {
            var a = AttributedString(s)
            a.font = .system(.body, design: .monospaced)
            a.foregroundColor = c
            return a
        }

        let src = jsonString
        let len = src.count
        var i = 0
        var out = AttributedString()

        while i < len {
            let idx = src.index(src.startIndex, offsetBy: i)
            let c = src[idx]
            if c.isWhitespace {
                var j = i
                while j < len {
                    let jdx = src.index(src.startIndex, offsetBy: j)
                    if !src[jdx].isWhitespace { break }
                    j += 1
                }
                out += piece(String(src[src.index(src.startIndex, offsetBy: i)..<src.index(src.startIndex, offsetBy: j)]), plainColor)
                i = j
                continue
            }
            if c == "\"" {
                let start = i
                i += 1
                while i < len {
                    let jdx = src.index(src.startIndex, offsetBy: i)
                    let ch = src[jdx]
                    if ch == "\\" {
                        i += 2
                        continue
                    }
                    if ch == "\"" {
                        i += 1
                        break
                    }
                    i += 1
                }
                var j = i
                while j < len {
                    let jdx = src.index(src.startIndex, offsetBy: j)
                    if !src[jdx].isWhitespace { break }
                    j += 1
                }
                let isKey = j < len && src[src.index(src.startIndex, offsetBy: j)] == ":"
                let slice = String(src[src.index(src.startIndex, offsetBy: start)..<src.index(src.startIndex, offsetBy: i)])
                out += piece(slice, isKey ? keyColor : stringColor)
                continue
            }
            if "{}[],:".contains(c) {
                out += piece(String(c), punctColor)
                i += 1
                continue
            }
            if c == "-" || c.isNumber {
                let start = i
                var j = i
                while j < len {
                    let jdx = src.index(src.startIndex, offsetBy: j)
                    let ch = src[jdx]
                    if !"-0123456789.eE+".contains(ch) { break }
                    j += 1
                }
                let slice = String(src[src.index(src.startIndex, offsetBy: start)..<src.index(src.startIndex, offsetBy: j)])
                out += piece(slice, numberColor)
                i = j
                continue
            }
            if src.dropFirst(i).hasPrefix("true") {
                out += piece("true", keywordColor)
                i += 4
                continue
            }
            if src.dropFirst(i).hasPrefix("false") {
                out += piece("false", keywordColor)
                i += 5
                continue
            }
            if src.dropFirst(i).hasPrefix("null") {
                out += piece("null", keywordColor)
                i += 4
                continue
            }
            out += piece(String(c), plainColor)
            i += 1
        }

        return out
    }
}

private enum JSONCodec {
    static func sortKeysDeep(_ value: Any) -> Any {
        switch value {
        case let arr as [Any]:
            return arr.map { sortKeysDeep($0) }
        case let dict as [String: Any]:
            var sorted: [String: Any] = [:]
            for k in dict.keys.sorted() {
                sorted[k] = sortKeysDeep(dict[k] as Any)
            }
            return sorted
        default:
            return value
        }
    }

    private static func escapeString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }

    private static func isBoolNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func stringify(_ value: Any, pretty: Bool, indentUnit: String) -> String {
        func inner(_ v: Any, depth: Int) -> String {
            switch v {
            case is NSNull:
                return "null"
            case let b as Bool:
                return b ? "true" : "false"
            case let n as NSNumber where isBoolNumber(n):
                return n.boolValue ? "true" : "false"
            case let i as Int:
                return "\(i)"
            case let n as Double:
                if n.isNaN || n.isInfinite { return "null" }
                return String(n)
            case let n as NSNumber:
                return n.stringValue
            case let s as String:
                return escapeString(s)
            case let arr as [Any]:
                if arr.isEmpty { return "[]" }
                if !pretty {
                    return "[" + arr.map { inner($0, depth: depth) }.joined(separator: ",") + "]"
                }
                let pad = String(repeating: indentUnit, count: depth + 1)
                let endPad = String(repeating: indentUnit, count: depth)
                let body = arr.map { "\n\(pad)" + inner($0, depth: depth + 1) }.joined(separator: ",")
                return "[\(body)\n\(endPad)]"
            case let dict as [String: Any]:
                let keys = Array(dict.keys)
                if dict.isEmpty { return "{}" }
                if !pretty {
                    let parts = keys.map { k in
                        escapeString(k) + ":" + inner(dict[k] as Any, depth: depth)
                    }
                    return "{" + parts.joined(separator: ",") + "}"
                }
                let pad = String(repeating: indentUnit, count: depth + 1)
                let endPad = String(repeating: indentUnit, count: depth)
                let parts = keys.map { k in
                    "\n\(pad)" + escapeString(k) + ": " + inner(dict[k] as Any, depth: depth + 1)
                }
                return "{" + parts.joined(separator: ",") + "\n\(endPad)}"
            default:
                return String(describing: v)
            }
        }
        return inner(value, depth: 0)
    }
}

private struct JSONInputEditor: NSViewRepresentable {
    @Binding var text: String
    var onPaste: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPaste: onPaste)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PasteReportingTextView()
        tv.onPasteCallback = { [weak tv] in
            guard let tv else { return }
            context.coordinator.syncFromTextView(tv)
            onPaste()
        }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = DiffToolTheme.surfaceNS
        tv.textColor = DiffToolTheme.textNS
        tv.insertionPointColor = DiffToolTheme.accentNS
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.string = text
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = DiffToolTheme.surfaceNS
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        scroll.autohidesScrollers = true
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PasteReportingTextView else { return }
        context.coordinator.textView = tv
        if tv.string != text {
            tv.string = text
        }
        tv.backgroundColor = DiffToolTheme.surfaceNS
        tv.textColor = DiffToolTheme.textNS
        tv.insertionPointColor = DiffToolTheme.accentNS
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onPaste: () -> Void
        weak var textView: PasteReportingTextView?

        init(text: Binding<String>, onPaste: @escaping () -> Void) {
            _text = text
            self.onPaste = onPaste
        }

        func syncFromTextView(_ tv: NSTextView) {
            text = tv.string
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            syncFromTextView(tv)
        }
    }
}

private final class PasteReportingTextView: NSTextView {
    var onPasteCallback: (() -> Void)?

    override func paste(_ sender: Any?) {
        super.paste(sender)
        onPasteCallback?()
    }
}

struct JSONFormatToolView: View {
    @State private var input = ""
    @State private var outputPlain = ""
    @State private var outputAttr = AttributedString()
    @State private var indent: JSONIndentChoice = .two
    @State private var sortKeys = false
    @State private var message = ""
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(messageIsError ? DiffToolTheme.error : DiffToolTheme.ok)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(messageIsError ? DiffToolTheme.error.opacity(0.12) : DiffToolTheme.ok.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(messageIsError ? DiffToolTheme.error.opacity(0.35) : DiffToolTheme.ok.opacity(0.3))
                    )
            }

            HStack(spacing: 10) {
                Button("格式化") { runFormat() }
                    .buttonStyle(DiffToolPrimaryButtonStyle())
                Button("压缩") { runMinify() }
                    .buttonStyle(DiffToolPrimaryButtonStyle())
                Button("复制结果") { copyOutput() }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                Button("清空") { clearAll() }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                Picker("缩进", selection: $indent) {
                    ForEach(JSONIndentChoice.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .frame(width: 140)
                Toggle("对象键名排序", isOn: $sortKeys)
            }
            .tint(DiffToolTheme.accent)
            .foregroundStyle(DiffToolTheme.text)

            GeometryReader { geo in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("输入".uppercased())
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        JSONInputEditor(text: $input) {
                            DispatchQueue.main.async { runFormat() }
                        }
                        .frame(minHeight: 120)
                    }
                    .frame(width: max(200, (geo.size.width - 12) / 2))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("结果".uppercased())
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        ScrollView {
                            Group {
                                if outputPlain.isEmpty {
                                    Text("点击「格式化」或「压缩」后显示")
                                        .foregroundStyle(DiffToolTheme.muted)
                                } else {
                                    Text(outputAttr)
                                }
                            }
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.lineDim))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(DiffToolTheme.border)
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiffToolTheme.background)
        .navigationTitle("JSON 格式化")
        .toolbarBackground(DiffToolTheme.background, for: .automatic)
    }

    private func showMessage(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private func parseInput() -> Any? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            showMessage("请输入 JSON 文本。", error: true)
            return nil
        }
        do {
            let data = Data(raw.utf8)
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            showMessage("解析失败：\(error.localizedDescription)", error: true)
            return nil
        }
    }

    private func applyOutput(_ str: String) {
        outputPlain = str
        outputAttr = JSONHighlight.attributed(from: str)
        showMessage("完成。", error: false)
    }

    private func preparedValue() -> Any? {
        guard var v = parseInput() else { return nil }
        if sortKeys {
            v = JSONCodec.sortKeysDeep(v)
        }
        return v
    }

    private func runFormat() {
        guard let v = preparedValue() else { return }
        let s = JSONCodec.stringify(v, pretty: true, indentUnit: indent.unit)
        applyOutput(s)
    }

    private func runMinify() {
        guard let v = preparedValue() else { return }
        let s = JSONCodec.stringify(v, pretty: false, indentUnit: "")
        applyOutput(s)
    }

    private func copyOutput() {
        guard !outputPlain.isEmpty else {
            showMessage("没有可复制的内容。", error: true)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(outputPlain, forType: .string) {
            showMessage("已复制到剪贴板。", error: false)
        } else {
            showMessage("复制失败，请手动全选复制。", error: true)
        }
    }

    private func clearAll() {
        input = ""
        outputPlain = ""
        outputAttr = AttributedString()
        message = ""
    }
}
