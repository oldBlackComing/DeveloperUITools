//
//  IOSUploadPrecheckToolView.swift
//  WYTools
//

import SwiftUI

struct IOSUploadPrecheckToolView: View {
    @State private var viewModel = IOSUploadPrecheckViewModel.shared

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("本工具会在本地执行 iOS 上传前预检（不真实上传），覆盖 archive/export、签名、元数据、资源与常见商店拦截问题。")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)

                HStack(spacing: 12) {
                    Button("选择目录…") {
                        viewModel.pickFolder()
                    }
                    .buttonStyle(DiffToolPrimaryButtonStyle())

                    Button("开始预检") {
                        Task { await viewModel.runPrecheck() }
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    .disabled(viewModel.selectedFolderPath.isEmpty || viewModel.isRunning)

                    if viewModel.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.currentStatus.isEmpty ? "执行中…" : viewModel.currentStatus)
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                    }
                }

                if !viewModel.selectedFolderPath.isEmpty {
                    Text("已选目录：\(viewModel.selectedFolderPath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DiffToolTheme.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(DiffToolTheme.border)
                        )
                }

                optionsSection(viewModel: viewModel)
                progressSection(viewModel: viewModel)
                runtimeSection(viewModel: viewModel)

                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(DiffToolTheme.error)
                }

                if let result = viewModel.result {
                    resultHeader(result: result)
                    issuesSection(result: result, severity: .error, title: "错误（Errors）")
                    issuesSection(result: result, severity: .warning, title: "警告（Warnings）")
                    issuesSection(result: result, severity: .info, title: "提示（Info）")
                    logSection(result: result)
                }
            }
            .padding(20)
        }
        .background(DiffToolTheme.background)
        .navigationTitle("iOS 上传预检")
    }

    @ViewBuilder
    private func optionsSection(viewModel: IOSUploadPrecheckViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选项")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)

            HStack(spacing: 10) {
                Text("Scheme")
                    .font(.caption2)
                    .foregroundStyle(DiffToolTheme.muted)
                TextField("留空自动识别", text: $viewModel.preferredScheme)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Text("配置（Configuration）")
                    .font(.caption2)
                    .foregroundStyle(DiffToolTheme.muted)
                Picker("配置", selection: $viewModel.configuration) {
                    Text("Release").tag("Release")
                    Text("Debug").tag("Debug")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            Toggle("构建后执行导出（Export Archive）", isOn: $viewModel.shouldExportArchive)
                .toggleStyle(.checkbox)
                .foregroundStyle(DiffToolTheme.text)
            Toggle("允许自动更新签名（allowProvisioningUpdates）", isOn: $viewModel.allowProvisioningUpdates)
                .toggleStyle(.checkbox)
                .foregroundStyle(DiffToolTheme.text)
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
    private func progressSection(viewModel: IOSUploadPrecheckViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("验证进度")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            ForEach(viewModel.progressItems) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(iconText(for: item.state))
                        .font(.caption)
                        .frame(width: 18, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(color(for: item.state))
                        if !item.message.isEmpty {
                            Text(item.message)
                                .font(.caption2)
                                .foregroundStyle(DiffToolTheme.muted)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
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
    private func runtimeSection(viewModel: IOSUploadPrecheckViewModel) -> some View {
        if !viewModel.runtimeLog.isEmpty || viewModel.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                Text("执行中日志")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
                if !viewModel.currentStatus.isEmpty {
                    Text("当前步骤：\(viewModel.currentStatus)")
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.text)
                }
                ScrollView {
                    Text(viewModel.runtimeLog.isEmpty ? "（暂无日志）" : viewModel.runtimeLog)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DiffToolTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(DiffToolTheme.border.opacity(0.35), lineWidth: 1)
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(DiffToolTheme.border)
            )
        }
    }

    @ViewBuilder
    private func resultHeader(result: IOSUploadPrecheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结果概览")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            Text("Scheme：\(result.scheme)")
                .foregroundStyle(DiffToolTheme.text)
            Text("错误：\(result.errorCount)  警告：\(result.warningCount)")
                .foregroundStyle(result.errorCount > 0 ? DiffToolTheme.error : DiffToolTheme.ok)
            if let archivePath = result.archivePath {
                Text("Archive 路径：\(archivePath)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(DiffToolTheme.text)
            }
            if let exportPath = result.exportPath {
                Text("Export 路径：\(exportPath)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(DiffToolTheme.text)
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
    private func issuesSection(
        result: IOSUploadPrecheckResult,
        severity: IOSUploadPrecheckSeverity,
        title: String
    ) -> some View {
        let filtered = result.issues.filter { $0.severity == severity }
        if filtered.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
                ForEach(filtered) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title)
                            .foregroundStyle(color(for: issue.severity))
                            .font(.subheadline.weight(.semibold))
                        Text(issue.detail)
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.text)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(DiffToolTheme.border.opacity(0.35), lineWidth: 1)
                    )
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
    }

    @ViewBuilder
    private func logSection(result: IOSUploadPrecheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原始构建日志（Raw Build Log）")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            ScrollView {
                Text(result.rawLog.isEmpty ? "（无输出）" : result.rawLog)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(DiffToolTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DiffToolTheme.border.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DiffToolTheme.border)
        )
    }

    private func color(for severity: IOSUploadPrecheckSeverity) -> Color {
        switch severity {
        case .error: return DiffToolTheme.error
        case .warning: return DiffToolTheme.onlyA
        case .info: return DiffToolTheme.muted
        }
    }

    private func color(for state: IOSUploadPrecheckTaskState) -> Color {
        switch state {
        case .pending: return DiffToolTheme.muted
        case .running: return DiffToolTheme.accent
        case .success: return DiffToolTheme.ok
        case .failed: return DiffToolTheme.error
        case .skipped: return DiffToolTheme.onlyA
        }
    }

    private func iconText(for state: IOSUploadPrecheckTaskState) -> String {
        switch state {
        case .pending: return "○"
        case .running: return "⟳"
        case .success: return "✓"
        case .failed: return "✗"
        case .skipped: return "–"
        }
    }
}

#Preview {
    NavigationStack {
        IOSUploadPrecheckToolView()
    }
    .frame(minWidth: 900, minHeight: 620)
}
