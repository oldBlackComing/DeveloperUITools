//
//  ContentView.swift
//  WYTools
//
//  Created by Developer_wy on 2026/4/16.
//

import SwiftUI

private enum ToolTab: String, CaseIterable, Identifiable, Hashable {
    case lineDiff = "文本行对比"
    case jsonFormat = "JSON 格式化"
    case imageCompress = "图片压缩"
    case lottie = "Lottie 预览"
    case localizationCompare = "本地化对比（Localization vs EN）"

    private static let sidebarOrderKey = "sidebar_tool_tab_order"

    /// 默认顺序：JSON 格式化 → 图片压缩 → 文本行对比 → Lottie 预览 → 本地化对比（Localization vs EN）
    static var defaultTabOrder: [ToolTab] {
        [.jsonFormat, .imageCompress, .lineDiff, .lottie, .localizationCompare]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .lineDiff: "text.alignleft"
        case .jsonFormat: "curlybraces"
        case .imageCompress: "photo.on.rectangle.angled"
        case .lottie: "play.rectangle.fill"
        case .localizationCompare: "globe"
        }
    }

    /// 从本地读取顺序；数据不完整或与当前枚举不一致时回退为 `defaultTabOrder`。
    static func loadSavedOrder() -> [ToolTab] {
        guard let raw = UserDefaults.standard.string(forKey: sidebarOrderKey), !raw.isEmpty else {
            return defaultTabOrder
        }
        let parsed = raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }
        let expected = Set(allCases)
        guard parsed.count == expected.count, Set(parsed) == expected else {
            return defaultTabOrder
        }
        return parsed
    }

    static func saveOrder(_ order: [ToolTab]) {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: sidebarOrderKey)
    }
}

struct ContentView: View {
    @State private var tabOrder: [ToolTab]
    @State private var selection: ToolTab

    init() {
        let order = ToolTab.loadSavedOrder()
        _tabOrder = State(initialValue: order)
        _selection = State(initialValue: order.first ?? .jsonFormat)
    }

    var body: some View {
        ZStack {
            DiffToolTheme.background.ignoresSafeArea()
            NavigationSplitView {
                List(selection: $selection) {
                    ForEach(tabOrder) { tab in
                        sidebarRow(tab)
                            .tag(tab)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(DiffToolTheme.background)
                    }
                    .onMove { source, destination in
                        tabOrder.move(fromOffsets: source, toOffset: destination)
                        ToolTab.saveOrder(tabOrder)
                    }
                }
                .navigationTitle("WYTools")
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
                .background(DiffToolTheme.background)
            } detail: {
                Group {
                    switch selection {
                    case .lineDiff:
                        LineDiffToolView()
                    case .jsonFormat:
                        JSONFormatToolView()
                    case .imageCompress:
                        ImageCompressToolView()
                    case .lottie:
                        LottieToolView()
                    case .localizationCompare:
                        LocalizationCompareToolView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DiffToolTheme.background)
            }
        }
        .tint(DiffToolTheme.accent)
    }

    @ViewBuilder
    private func sidebarRow(_ tab: ToolTab) -> some View {
        let isSelected = tab == selection
        Label(tab.rawValue, systemImage: tab.systemImage)
            .foregroundStyle(isSelected ? DiffToolTheme.text : DiffToolTheme.muted)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    DiffToolTheme.accent.opacity(0.28),
                                    DiffToolTheme.accent.opacity(0.12),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    Color(red: 129 / 255, green: 140 / 255, blue: 248 / 255).opacity(0.65),
                                    lineWidth: 1
                                )
                        )
                }
            }
            .contentShape(Rectangle())
    }
}

#Preview {
    ContentView()
        .frame(minWidth: 900, minHeight: 600)
}
