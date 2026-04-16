//
//  LineDiffToolView.swift
//  WYTools
//

import SwiftUI

private struct LineDiffEngine {
    struct LineItem: Hashable {
        let display: String
        let key: String
    }

    static func parseLines(_ text: String, ignoreCase: Bool, ignoreEmpty: Bool) -> [LineItem] {
        text.split(whereSeparator: \.isNewline).map { line in
            let display = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ignoreCase ? display.lowercased() : display
            return LineItem(display: display, key: key)
        }
        .filter { !ignoreEmpty || !$0.display.isEmpty }
    }

    static func keyToDisplayMap(_ items: [LineItem]) -> [String: String] {
        var map: [String: String] = [:]
        for item in items where map[item.key] == nil {
            map[item.key] = item.display
        }
        return map
    }

    static func compare(textA: String, textB: String, ignoreCase: Bool, ignoreEmpty: Bool)
        -> (onlyA: [String], onlyB: [String], both: [String], mapA: [String: String], mapB: [String: String])
    {
        let itemsA = parseLines(textA, ignoreCase: ignoreCase, ignoreEmpty: ignoreEmpty)
        let itemsB = parseLines(textB, ignoreCase: ignoreCase, ignoreEmpty: ignoreEmpty)
        let setA = Set(itemsA.map(\.key))
        let setB = Set(itemsB.map(\.key))
        let mapA = keyToDisplayMap(itemsA)
        let mapB = keyToDisplayMap(itemsB)
        let onlyA = setA.subtracting(setB).sorted()
        let onlyB = setB.subtracting(setA).sorted()
        let both = setA.intersection(setB).sorted()
        return (onlyA, onlyB, both, mapA, mapB)
    }
}

struct LineDiffToolView: View {
    @State private var textA = ""
    @State private var textB = ""
    @State private var ignoreCase = false
    @State private var ignoreEmpty = true
    @State private var result: (
        onlyA: [String],
        onlyB: [String],
        both: [String],
        mergedDisplay: [String: String]
    )?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("分别粘贴两组数据（每行一条）。会按「行」对比：标出只在第一组、只在第二组，以及两组都有的行。")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)

                HStack(alignment: .top, spacing: 16) {
                    panel(title: "第一组", text: $textA, placeholder: "每行一条，例如 GUID…")
                    panel(title: "第二组", text: $textB, placeholder: "每行一条…")
                }
                .frame(minHeight: 220)

                HStack(spacing: 12) {
                    Button("对比差异") { runCompare() }
                        .buttonStyle(DiffToolPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("清空") {
                        textA = ""
                        textB = ""
                        result = nil
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    Toggle("忽略大小写", isOn: $ignoreCase)
                    Toggle("忽略空行", isOn: $ignoreEmpty)
                }
                .tint(DiffToolTheme.accent)
                .foregroundStyle(DiffToolTheme.text)

                if let result {
                    resultsSection(result)
                }
            }
            .padding(20)
        }
        .background(DiffToolTheme.background)
        .navigationTitle("文本行对比")
        .toolbarBackground(DiffToolTheme.background, for: .automatic)
    }

    @ViewBuilder
    private func panel(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(DiffToolTheme.text)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(DiffToolTheme.border)
                )
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(DiffToolTheme.muted.opacity(0.85))
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func resultsSection(_ r: (
        onlyA: [String],
        onlyB: [String],
        both: [String],
        mergedDisplay: [String: String]
    )) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            resultBlock(
                title: "仅在第一组（第二组没有）",
                keys: r.onlyA,
                display: r.mergedDisplay,
                accent: DiffToolTheme.onlyA,
                stat: r.onlyA.isEmpty
                    ? "与第二组相比，没有多出来的行。"
                    : "共 \(r.onlyA.count) 行"
            )
            themeDivider
            resultBlock(
                title: "仅在第二组（第一组没有）",
                keys: r.onlyB,
                display: r.mergedDisplay,
                accent: DiffToolTheme.onlyB,
                stat: r.onlyB.isEmpty
                    ? "与第一组相比，没有多出来的行。"
                    : "共 \(r.onlyB.count) 行"
            )
            themeDivider
            resultBlock(
                title: "两组共有",
                keys: r.both,
                display: r.mergedDisplay,
                accent: DiffToolTheme.bothGreen,
                stat: "共 \(r.both.count) 行相同"
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DiffToolTheme.border)
        )
    }

    private var themeDivider: some View {
        Rectangle()
            .fill(DiffToolTheme.border)
            .frame(height: 1)
    }

    private func resultBlock(
        title: String,
        keys: [String],
        display: [String: String],
        accent: Color,
        stat: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
            if keys.isEmpty {
                Text("无")
                    .italic()
                    .foregroundStyle(DiffToolTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(keys, id: \.self) { k in
                        Text(display[k] ?? k)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DiffToolTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DiffToolTheme.lineDim))
                    }
                }
            }
            Text(stat)
                .font(.caption2)
                .foregroundStyle(DiffToolTheme.muted)
        }
        .padding(.vertical, 8)
    }

    private func runCompare() {
        let out = LineDiffEngine.compare(
            textA: textA,
            textB: textB,
            ignoreCase: ignoreCase,
            ignoreEmpty: ignoreEmpty
        )
        var merged = out.mapA
        for (k, v) in out.mapB { merged[k] = merged[k] ?? v }
        result = (out.onlyA, out.onlyB, out.both, merged)
    }
}
