//
//  DiffToolTheme.swift
//  WYTools
//
//  与 DiffTool 网页 :root 变量一致的深蓝暗色风格
//

import AppKit
import SwiftUI

enum DiffToolTheme {
    /// #0f1419
    static let background = Color(red: 15 / 255, green: 20 / 255, blue: 25 / 255)
    /// #1a2332
    static let surface = Color(red: 26 / 255, green: 35 / 255, blue: 50 / 255)
    /// #2d3a4d
    static let border = Color(red: 45 / 255, green: 58 / 255, blue: 77 / 255)
    /// #e7ecf3
    static let text = Color(red: 231 / 255, green: 236 / 255, blue: 243 / 255)
    /// #8b9cb3
    static let muted = Color(red: 139 / 255, green: 156 / 255, blue: 179 / 255)
    /// #6366f1
    static let accent = Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255)

    /// #f59e0b
    static let onlyA = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
    /// #38bdf8
    static let onlyB = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
    /// #34d399
    static let bothGreen = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)

    /// #f87171
    static let error = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
    /// #6ee7b7
    static let ok = Color(red: 110 / 255, green: 231 / 255, blue: 183 / 255)

    /// 结果区行背景，与网页 rgba(0,0,0,0.25) 接近
    static let lineDim = Color.black.opacity(0.25)

    static var textNS: NSColor { nsColor(text) }
    static var surfaceNS: NSColor { nsColor(surface) }
    static var backgroundNS: NSColor { nsColor(background) }
    static var accentNS: NSColor { nsColor(accent) }

    private static func nsColor(_ color: Color) -> NSColor {
        NSColor(color)
    }
}

struct DiffToolPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(DiffToolTheme.accent.opacity(configuration.isPressed ? 0.85 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DiffToolSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(DiffToolTheme.surface.opacity(configuration.isPressed ? 0.92 : 1))
            .foregroundStyle(DiffToolTheme.text)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DiffToolTheme.border, lineWidth: 1)
            )
    }
}
