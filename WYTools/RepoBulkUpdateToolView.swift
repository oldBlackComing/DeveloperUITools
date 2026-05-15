//
//  RepoBulkUpdateToolView.swift
//  WYTools
//

import SwiftUI

struct RepoBulkUpdateToolView: View {
    @State private var viewModel = RepoBulkUpdateViewModel.shared
    @State private var repoListTab: RepoListTab = .included
    @State private var isActionBarPinned: Bool = false
    private let visibleLogLineLimit = 300

    private enum RepoListTab: String, CaseIterable, Identifiable {
        case included = "Included"
        case blackRoom = "Black Room"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                Text("Batch update all local branches for repositories under one folder. If merge conflict happens, resolve in SourceTree then continue.")
                    .font(.subheadline)
                    .foregroundStyle(DiffToolTheme.muted)

                folderSection(viewModel: viewModel)

                Section {
                    logSection(viewModel: viewModel)
                    repositoriesSection(viewModel: viewModel)
                } header: {
                    actionSection(viewModel: viewModel, isPinned: isActionBarPinned)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: RepoBulkActionBarMinYPreferenceKey.self,
                                        value: geo.frame(in: .named("repo-bulk-update-scroll")).minY
                                    )
                            }
                        )
                }
            }
            .padding(20)
        }
        .coordinateSpace(name: "repo-bulk-update-scroll")
        .onPreferenceChange(RepoBulkActionBarMinYPreferenceKey.self) { minY in
            let pinned = minY <= 0.5
            if pinned != isActionBarPinned {
                isActionBarPinned = pinned
            }
        }
        .background(DiffToolTheme.background)
        .navigationTitle("Repository Bulk Update")
    }

    @ViewBuilder
    private func folderSection(viewModel: RepoBulkUpdateViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)

            HStack(spacing: 12) {
                TextField("Root folder path", text: $viewModel.selectedFolderPath)
                    .textFieldStyle(.roundedBorder)
                Button("Select Folder…") {
                    viewModel.pickFolder()
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
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
    private func actionSection(viewModel: RepoBulkUpdateViewModel, isPinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Scan Repositories") {
                    Task { await viewModel.scanRepositories() }
                }
                .buttonStyle(DiffToolPrimaryButtonStyle())
                .disabled(viewModel.isRunning)

                Button("Select All") {
                    for idx in viewModel.repositories.indices {
                        if viewModel.repositories[idx].isBlacklisted {
                            viewModel.repositories[idx].isSelected = false
                        } else {
                            viewModel.repositories[idx].isSelected = true
                        }
                    }
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
                .disabled(viewModel.repositories.isEmpty || viewModel.isRunning)

                Button("Clear Selection") {
                    for idx in viewModel.repositories.indices {
                        viewModel.repositories[idx].isSelected = false
                    }
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
                .disabled(viewModel.repositories.isEmpty || viewModel.isRunning)

                Button("Start Update") {
                    Task { await viewModel.startUpdate() }
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
                .disabled(viewModel.repositories.isEmpty || viewModel.isRunning || viewModel.awaitingManualResolution)

                Button("Stop") {
                    viewModel.stopExecution()
                }
                .buttonStyle(DiffToolSecondaryButtonStyle())
                .disabled(!viewModel.isRunning && !viewModel.awaitingManualResolution)
            }

            if viewModel.awaitingManualResolution {
                HStack(spacing: 10) {
                    Text(viewModel.manualResolutionHintText.isEmpty ? "Detected manual action required. Handle in SourceTree, then click:" : viewModel.manualResolutionHintText)
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.onlyA)
                    Button("Open in SourceTree") {
                        viewModel.openPendingRepositoryInSourceTree()
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    Button("处理完成，继续") {
                        Task { await viewModel.continueAfterManualResolution() }
                    }
                    .buttonStyle(DiffToolPrimaryButtonStyle())
                }
            }

            if viewModel.totalRepositoryCount > 0 {
                let total = max(viewModel.totalRepositoryCount, 1)
                let progress = min(max(Double(viewModel.processedRepositoryCount) / Double(total), 0), 1)
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                Text("Status: \(viewModel.operationStatusText) · \(Int(progress * 100))% · \(viewModel.processedRepositoryCount)/\(viewModel.totalRepositoryCount)")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
            } else {
                Text("Status: \(viewModel.operationStatusText)")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
            }

            if !viewModel.currentRepositoryPath.isEmpty {
                Text("Current: \(viewModel.currentRepositoryPath)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(DiffToolTheme.text)
                    .textSelection(.enabled)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.error)
                    .textSelection(.enabled)
            }

            if !viewModel.summaryMessage.isEmpty {
                Text(viewModel.summaryMessage)
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.ok)
            }
        }
        .padding(isPinned ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: isPinned ? 6 : 10).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: isPinned ? 6 : 10)
                .strokeBorder(DiffToolTheme.border)
        )
        .shadow(color: .black.opacity(isPinned ? 0.2 : 0), radius: isPinned ? 8 : 0, y: isPinned ? 2 : 0)
        .overlay(alignment: .bottom) {
            if isPinned {
                Rectangle()
                    .fill(DiffToolTheme.border)
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func logSection(viewModel: RepoBulkUpdateViewModel) -> some View {
        let bottomID = "repo-bulk-update-log-bottom"
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime log")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.runtimeLog.isEmpty ? "No logs yet." : visibleRuntimeLogText(viewModel.runtimeLog))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DiffToolTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(8)
                }
                .onChange(of: viewModel.runtimeLog) { _, _ in
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
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

    @ViewBuilder
    private func repositoriesSection(viewModel: RepoBulkUpdateViewModel) -> some View {
        let includedRepos = includedBindings(viewModel: viewModel)
        let blackRoomRepos = blackRoomBindings(viewModel: viewModel)
        VStack(alignment: .leading, spacing: 8) {
            Text("Repositories \(viewModel.repositories.count) · Included \(includedRepos.count) · Black Room \(blackRoomRepos.count)")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            Picker("Repository list tab", selection: $repoListTab) {
                Text("Included").tag(RepoListTab.included)
                Text("Black Room").tag(RepoListTab.blackRoom)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            if viewModel.repositories.isEmpty {
                Text("No repositories yet. Click 'Scan Repositories' first.")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
            } else {
                let sourceList = repoListTab == .included ? includedRepos : blackRoomRepos
                if sourceList.isEmpty {
                    Text(repoListTab == .blackRoom ? "Black Room is empty." : "No included repositories.")
                        .font(.caption)
                        .foregroundStyle(DiffToolTheme.muted)
                }
                ForEach(sourceList) { $repo in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Toggle("", isOn: $repo.isSelected)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(repo.isBlacklisted)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(repo.relativePath)
                                if repo.isBlacklisted {
                                    Text("Ignored")
                                        .font(.caption2)
                                        .foregroundStyle(DiffToolTheme.onlyA)
                                }
                            }
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(DiffToolTheme.text)
                            Text(repo.detailMessage)
                                .font(.caption)
                                .foregroundStyle(statusColor(repo.state))
                        }
                        actionTagButton(title: "Open Folder", tint: DiffToolTheme.onlyB) {
                            viewModel.openRepositoryDirectory(for: repo.id)
                        }
                        actionTagButton(title: "Open SourceTree", tint: DiffToolTheme.onlyA) {
                            viewModel.openRepositoryInSourceTree(for: repo.id)
                        }
                        Button(repo.isBlacklisted ? "Remove" : "Black Room") {
                            viewModel.toggleBlacklist(for: repo.id)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill((repo.isBlacklisted ? DiffToolTheme.ok : DiffToolTheme.onlyA).opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(repo.isBlacklisted ? DiffToolTheme.ok : DiffToolTheme.onlyA, lineWidth: 1)
                        )
                        .foregroundStyle(repo.isBlacklisted ? DiffToolTheme.ok : DiffToolTheme.onlyA)
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Text(stateText(repo.state))
                            .font(.caption)
                            .foregroundStyle(statusColor(repo.state))
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DiffToolTheme.border)
        )
    }

    private func includedBindings(viewModel: RepoBulkUpdateViewModel) -> [Binding<RepoUpdateItem>] {
        $viewModel.repositories.filter { !$0.wrappedValue.isBlacklisted }
    }

    private func blackRoomBindings(viewModel: RepoBulkUpdateViewModel) -> [Binding<RepoUpdateItem>] {
        $viewModel.repositories.filter { $0.wrappedValue.isBlacklisted }
    }

    private func stateText(_ state: RepoUpdateRowState) -> String {
        switch state {
        case .pending: return "Pending"
        case .running: return "Running"
        case .success: return "Success"
        case .failed: return "Failed"
        case .waitingUser: return "Manual Action"
        }
    }

    private func statusColor(_ state: RepoUpdateRowState) -> Color {
        switch state {
        case .pending: return DiffToolTheme.muted
        case .running: return DiffToolTheme.onlyB
        case .success: return DiffToolTheme.ok
        case .failed: return DiffToolTheme.error
        case .waitingUser: return DiffToolTheme.onlyA
        }
    }

    private func actionTagButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1)
            )
            .foregroundStyle(tint)
            .buttonStyle(.plain)
    }

    private func visibleRuntimeLogText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count <= visibleLogLineLimit { return lines.joined(separator: "\n") }
        return lines.suffix(visibleLogLineLimit).joined(separator: "\n")
    }
}

private struct RepoBulkActionBarMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    NavigationStack {
        RepoBulkUpdateToolView()
    }
    .frame(minWidth: 980, minHeight: 700)
}
