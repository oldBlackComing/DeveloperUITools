//
//  IOSUploadPrecheckViewModel.swift
//  WYTools
//

import AppKit
import Foundation

enum IOSUploadPrecheckTaskState: Sendable {
    case pending
    case running
    case success
    case failed
    case skipped
}

struct IOSUploadPrecheckTaskItem: Identifiable, Sendable {
    let id: String
    let title: String
    var state: IOSUploadPrecheckTaskState
    var message: String
}

@MainActor
@Observable
final class IOSUploadPrecheckViewModel {
    static let shared = IOSUploadPrecheckViewModel()

    var selectedFolderPath: String = ""
    var preferredScheme: String = ""
    var configuration: String = "Release"
    var shouldExportArchive: Bool = true
    var allowProvisioningUpdates: Bool = true

    var isRunning: Bool = false
    var errorMessage: String?
    var result: IOSUploadPrecheckResult?
    var currentStatus: String = ""
    var runtimeLog: String = ""
    var progressItems: [IOSUploadPrecheckTaskItem] = []
    private var runningTask: Task<Void, Never>?

    init() {
        resetProgressItems()
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "请选择 iOS 工程根目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolderPath = url.path
        errorMessage = nil
    }

    func runPrecheck() async {
        if isRunning { return }
        guard !selectedFolderPath.isEmpty else {
            errorMessage = "请先选择目录。"
            return
        }
        let rootURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)

        isRunning = true
        errorMessage = nil
        result = nil
        currentStatus = "准备开始…"
        runtimeLog = ""
        resetProgressItems()
        appendRuntimeLog("准备执行预检。")

        let preferredScheme = preferredScheme
        let configuration = configuration
        let shouldExportArchive = shouldExportArchive
        let allowProvisioningUpdates = allowProvisioningUpdates

        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isRunning = false
                }
            }
            do {
                let value = try await IOSUploadPrecheckScanner.run(
                    input: .init(
                        rootFolder: rootURL,
                        preferredScheme: preferredScheme,
                        configuration: configuration,
                        shouldExportArchive: shouldExportArchive,
                        allowProvisioningUpdates: allowProvisioningUpdates
                    ),
                    onStatus: { [weak self] status in
                        Task { @MainActor in
                            guard let self else { return }
                            self.currentStatus = status
                            self.appendRuntimeLog(status)
                        }
                    },
                    onStep: { [weak self] stepID, state, message in
                        Task { @MainActor in
                            guard let self else { return }
                            self.updateProgressItem(id: stepID, state: state, message: message)
                        }
                    }
                )
                await MainActor.run {
                    self.result = value
                    if self.currentStatus.isEmpty {
                        self.currentStatus = "预检完成。"
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if self.currentStatus.isEmpty {
                        self.currentStatus = "预检失败。"
                    }
                    self.appendRuntimeLog(self.errorMessage ?? "未知错误")
                }
            }
        }
        await runningTask?.value
    }

    private func resetProgressItems() {
        progressItems = [
            .init(id: IOSUploadPrecheckScanner.StepID.detectProject.rawValue, title: "识别工程与 Scheme", state: .pending, message: ""),
            .init(id: IOSUploadPrecheckScanner.StepID.staticChecks.rawValue, title: "静态规则检查", state: .pending, message: ""),
            .init(id: IOSUploadPrecheckScanner.StepID.archive.rawValue, title: "Archive 构建", state: .pending, message: ""),
            .init(id: IOSUploadPrecheckScanner.StepID.archiveArtifactChecks.rawValue, title: "归档产物校验", state: .pending, message: ""),
            .init(id: IOSUploadPrecheckScanner.StepID.export.rawValue, title: "Export 导出校验", state: .pending, message: ""),
            .init(id: IOSUploadPrecheckScanner.StepID.finished.rawValue, title: "完成汇总", state: .pending, message: ""),
        ]
    }

    private func updateProgressItem(id: String, state: IOSUploadPrecheckTaskState, message: String) {
        guard let index = progressItems.firstIndex(where: { $0.id == id }) else { return }
        progressItems[index].state = state
        progressItems[index].message = message
    }

    private func appendRuntimeLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(text)"
        if runtimeLog.isEmpty {
            runtimeLog = line
        } else {
            runtimeLog.append("\n")
            runtimeLog.append(line)
        }
    }
}
