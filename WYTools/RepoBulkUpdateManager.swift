//
//  RepoBulkUpdateManager.swift
//  WYTools
//

import AppKit
import Foundation

enum RepoUpdateRowState {
    case pending
    case running
    case success
    case failed
    case waitingUser
}

struct RepoUpdateItem: Identifiable {
    let id: String
    let repoURL: URL
    let relativePath: String
    var isBlacklisted: Bool = false
    var isSelected: Bool = true
    var state: RepoUpdateRowState = .pending
    var detailMessage: String = "Ready"
}

private struct RepoUpdateCommandResult {
    let exitCode: Int32
    let output: String
}

private struct RepoExecutionContext {
    let repoIndex: Int
    let remote: String
    let originalBranch: String
    let localBranches: [String]
}

private enum RepoUpdateTaskKind {
    case pull(remote: String, branch: String)
    case restore(branch: String)
}

private struct RepoUpdateTask {
    let repoIndex: Int
    let kind: RepoUpdateTaskKind
}

private enum RepoUpdateFailure: LocalizedError {
    case mergeConflict(repoIndex: Int, branch: String, message: String)
    case localChanges(repoIndex: Int, branch: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .mergeConflict(_, _, message):
            return message
        case let .localChanges(_, _, message):
            return message
        }
    }
}

private enum RepoManualResolutionKind {
    case mergeConflict
    case localChanges
}

@MainActor
@Observable
final class RepoBulkUpdateViewModel {
    static let shared = RepoBulkUpdateViewModel()

    var selectedFolderPath: String = "/Users/develop/Desktop/iOS"
    var repositories: [RepoUpdateItem] = []

    var isRunning: Bool = false
    var isPaused: Bool = false
    var awaitingManualResolution: Bool = false
    var errorMessage: String?
    var summaryMessage: String = ""
    var operationStatusText: String = "Idle"
    var currentRepositoryPath: String = ""
    var processedRepositoryCount: Int = 0
    var totalRepositoryCount: Int = 0
    var successRepositoryCount: Int = 0
    var failedRepositoryCount: Int = 0
    var runtimeLog: String = ""
    var manualResolutionHintText: String = ""

    private var stopRequested: Bool = false
    private var activeGitProcess: Process?
    private var runningTask: Task<Void, Never>?
    private var tasks: [RepoUpdateTask] = []
    private var taskCursor: Int = 0
    private var pendingConflictRepoIndex: Int?
    private var pendingConflictBranch: String?
    private var pendingManualResolutionKind: RepoManualResolutionKind?
    private var pendingRuntimeLogLines: [String] = []
    private var committedRuntimeLogLines: [String] = []
    private let maxRuntimeLogLineCount = 1000
    private let maxRuntimeLogLineLength = 800
    private var runtimeLogFlushTask: Task<Void, Never>?
    private let runtimeLogFlushIntervalNanos: UInt64 = 150_000_000
    private static let runtimeLogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let ignoredDirectoryNames: Set<String> = [
        "deriveddata",
        "sourcepackages",
        ".build",
        "build",
        "pods",
        "carthage",
        "node_modules",
        "xcode-build-server",
    ]
    private let blacklistedReposKey = "repo_bulk_update_blacklisted_repositories"
    private var blacklistedRepoPaths: Set<String> = []

    init() {
        blacklistedRepoPaths = Set(UserDefaults.standard.stringArray(forKey: blacklistedReposKey) ?? [])
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the root folder that contains repositories."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolderPath = url.path
    }

    func scanRepositories() async {
        guard !isRunning else { return }
        guard !selectedFolderPath.isEmpty else { return }

        resetLog()
        operationStatusText = "Scanning repositories..."
        errorMessage = nil
        summaryMessage = ""
        repositories = []

        let rootURL = URL(fileURLWithPath: selectedFolderPath, isDirectory: true)
        do {
            let repoURLs = try discoverRepositories(in: rootURL)
            repositories = repoURLs.map { url in
                let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let blacklisted = blacklistedRepoPaths.contains(url.path)
                return RepoUpdateItem(id: url.path, repoURL: url, relativePath: relative, isBlacklisted: blacklisted, isSelected: !blacklisted)
            }
            operationStatusText = "Scan completed."
            summaryMessage = "Scanned \(repositories.count) repositories."
            appendLog(summaryMessage)
        } catch {
            errorMessage = error.localizedDescription
            operationStatusText = "Scan failed."
            appendLog("Scan failed: \(error.localizedDescription)")
        }
    }

    func startUpdate() async {
        guard !isRunning else { return }
        isRunning = true
        awaitingManualResolution = false
        stopRequested = false
        isPaused = false
        taskCursor = 0
        tasks = []
        pendingConflictRepoIndex = nil
        pendingConflictBranch = nil
        pendingManualResolutionKind = nil
        errorMessage = nil
        summaryMessage = ""
        manualResolutionHintText = ""
        resetLog()

        let selectedIndices = repositories.indices.filter { repositories[$0].isSelected && !repositories[$0].isBlacklisted }
        guard !selectedIndices.isEmpty else {
            errorMessage = "Please select at least one non-blacklisted repository."
            isRunning = false
            return
        }

        processedRepositoryCount = 0
        totalRepositoryCount = selectedIndices.count
        successRepositoryCount = 0
        failedRepositoryCount = 0
        for index in repositories.indices {
            repositories[index].state = .pending
            if repositories[index].isBlacklisted {
                repositories[index].isSelected = false
                repositories[index].detailMessage = "Ignored by blacklist."
            } else if repositories[index].isSelected {
                repositories[index].detailMessage = "Queued"
            } else {
                repositories[index].detailMessage = "Not selected."
            }
        }
        operationStatusText = "Preparing tasks..."
        appendLog("Building update tasks for \(selectedIndices.count) repositories.")

        do {
            let contexts = await buildExecutionContexts(repoIndices: selectedIndices)
            if stopRequested {
                finalizeRun()
                return
            }
            tasks = buildTasks(from: contexts)
            if tasks.isEmpty {
                if failedRepositoryCount > 0 {
                    summaryMessage = "No pending branch updates. Success: \(successRepositoryCount), Failed: \(failedRepositoryCount)."
                    operationStatusText = "Completed with issues."
                } else if successRepositoryCount > 0 {
                    summaryMessage = "All selected repositories are already up to date."
                    operationStatusText = "Completed."
                } else {
                    summaryMessage = "No branches found to update."
                    operationStatusText = "Completed."
                }
                appendLog(summaryMessage)
                isRunning = false
                return
            }
            runningTask = Task { [weak self] in
                await self?.executeTasksLoop()
            }
        } catch {
            errorMessage = error.localizedDescription
            operationStatusText = "Task preparation failed."
            appendLog("Failed to build tasks: \(error.localizedDescription)")
            isRunning = false
        }
    }

    func pauseExecution() {
        guard isRunning else { return }
        guard !isPaused else { return }
        isPaused = true
        operationStatusText = "Paused"
        appendLog("Paused by user.")
    }

    func resumeExecution() {
        guard isRunning else { return }
        guard isPaused else { return }
        isPaused = false
        operationStatusText = "Resuming..."
        appendLog("Resumed by user.")
    }

    func stopExecution() {
        guard isRunning || awaitingManualResolution else { return }
        stopRequested = true
        isPaused = false
        awaitingManualResolution = false
        pendingManualResolutionKind = nil
        manualResolutionHintText = ""
        operationStatusText = "Stopping..."
        appendLog("Stop requested by user.")
        activeGitProcess?.terminate()
        runningTask?.cancel()
        finalizeRun()
    }

    func continueAfterManualResolution() async {
        guard awaitingManualResolution else { return }
        guard let repoIndex = pendingConflictRepoIndex,
              let branch = pendingConflictBranch else { return }

        let repo = repositories[repoIndex]
        do {
            switch pendingManualResolutionKind {
            case .mergeConflict:
                try await ensureConflictResolved(repoURL: repo.repoURL)
                taskCursor += 1
            case .localChanges:
                try await ensureWorkingTreeClean(repoURL: repo.repoURL)
            case .none:
                taskCursor += 1
            }
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Still blocked on \(repo.relativePath) branch \(branch): \(error.localizedDescription)")
            return
        }

        appendLog("Manual handling completed for \(repo.relativePath) branch \(branch), continuing.")
        awaitingManualResolution = false
        manualResolutionHintText = ""
        errorMessage = nil
        pendingConflictRepoIndex = nil
        pendingConflictBranch = nil
        pendingManualResolutionKind = nil
        isRunning = true
        runningTask = Task { [weak self] in
            await self?.executeTasksLoop()
        }
    }

    func openPendingRepositoryInSourceTree() {
        guard let repoIndex = pendingConflictRepoIndex else { return }
        openRepositoryInSourceTree(repoURL: repositories[repoIndex].repoURL)
    }

    func openRepositoryDirectory(for repoID: String) {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repo.repoURL])
    }

    func openRepositoryInSourceTree(for repoID: String) {
        guard let repo = repositories.first(where: { $0.id == repoID }) else { return }
        openRepositoryInSourceTree(repoURL: repo.repoURL)
    }

    func toggleBlacklist(for repoID: String) {
        guard let index = repositories.firstIndex(where: { $0.id == repoID }) else { return }
        repositories[index].isBlacklisted.toggle()
        if repositories[index].isBlacklisted {
            repositories[index].isSelected = false
            repositories[index].detailMessage = "Ignored by blacklist."
            blacklistedRepoPaths.insert(repositories[index].repoURL.path)
        } else {
            repositories[index].detailMessage = "Ready"
            blacklistedRepoPaths.remove(repositories[index].repoURL.path)
        }
        UserDefaults.standard.set(Array(blacklistedRepoPaths), forKey: blacklistedReposKey)
    }

    // MARK: - Execution

    private func executeTasksLoop() async {
        while taskCursor < tasks.count {
            if Task.isCancelled || stopRequested {
                break
            }
            await waitIfPaused()
            if stopRequested { break }

            let task = tasks[taskCursor]
            do {
                try await execute(task: task)
                taskCursor += 1
            } catch RepoUpdateFailure.mergeConflict(let repoIndex, let branch, let message) {
                repositories[repoIndex].state = .waitingUser
                repositories[repoIndex].detailMessage = "Conflict on \(branch). Resolve in SourceTree then continue."
                pendingConflictRepoIndex = repoIndex
                pendingConflictBranch = branch
                pendingManualResolutionKind = .mergeConflict
                awaitingManualResolution = true
                isRunning = false
                manualResolutionHintText = "检测到合并冲突，请先在 SourceTree 处理后继续。"
                operationStatusText = "Waiting manual conflict resolution"
                appendLog("Conflict detected: \(message)")
                return
            } catch RepoUpdateFailure.localChanges(let repoIndex, let branch, let message) {
                repositories[repoIndex].state = .waitingUser
                repositories[repoIndex].detailMessage = makeLocalChangeHint(branch: branch, rawMessage: message)
                pendingConflictRepoIndex = repoIndex
                pendingConflictBranch = branch
                pendingManualResolutionKind = .localChanges
                awaitingManualResolution = true
                isRunning = false
                manualResolutionHintText = "检测到本地未提交改动或工作区阻塞，请在 SourceTree 处理（提交/暂存/还原）后继续。"
                operationStatusText = "Waiting manual local-change resolution"
                appendLog("Manual action required: \(message)")
                return
            } catch {
                markTaskFailure(task: task, message: error.localizedDescription)
                taskCursor += 1
            }
        }
        finalizeRun()
    }

    private func execute(task: RepoUpdateTask) async throws {
        let repo = repositories[task.repoIndex]
        currentRepositoryPath = repo.relativePath
        repositories[task.repoIndex].state = .running

        switch task.kind {
        case let .pull(remote, branch):
            operationStatusText = "Updating \(repo.relativePath) [\(branch)]"
            repositories[task.repoIndex].detailMessage = "Pulling \(branch)..."
            do {
                try await runGitLogged(in: repo.repoURL, arguments: ["checkout", branch])
            } catch {
                let message = error.localizedDescription
                if isLocalChangeBlockedMessage(message) {
                    throw RepoUpdateFailure.localChanges(
                        repoIndex: task.repoIndex,
                        branch: branch,
                        message: message
                    )
                }
                throw error
            }
            do {
                try await runGitLogged(in: repo.repoURL, arguments: ["pull", "--no-rebase", remote, branch])
            } catch {
                let message = error.localizedDescription
                if isMergeConflictMessage(message) {
                    throw RepoUpdateFailure.mergeConflict(
                        repoIndex: task.repoIndex,
                        branch: branch,
                        message: message
                    )
                }
                if isLocalChangeBlockedMessage(message) {
                    throw RepoUpdateFailure.localChanges(
                        repoIndex: task.repoIndex,
                        branch: branch,
                        message: message
                    )
                }
                throw error
            }
        case let .restore(branch):
            operationStatusText = "Restoring branch for \(repo.relativePath)"
            repositories[task.repoIndex].detailMessage = "Restoring branch \(branch)"
            _ = try? await runGitLogged(in: repo.repoURL, arguments: ["checkout", branch])
            repositories[task.repoIndex].state = .success
            repositories[task.repoIndex].detailMessage = "Updated"
            processedRepositoryCount += 1
            successRepositoryCount += 1
        }
    }

    private func markTaskFailure(task: RepoUpdateTask, message: String) {
        switch task.kind {
        case .pull:
            repositories[task.repoIndex].state = .failed
            repositories[task.repoIndex].detailMessage = message
        case .restore:
            if repositories[task.repoIndex].state != .success {
                repositories[task.repoIndex].state = .failed
                repositories[task.repoIndex].detailMessage = "Failed to restore original branch."
            }
            processedRepositoryCount += 1
            failedRepositoryCount += 1
        }
        appendLog("Failed: \(repositories[task.repoIndex].relativePath) - \(message)")
    }

    private func finalizeRun() {
        if isRunning == false && awaitingManualResolution {
            return
        }
        isRunning = false
        runningTask = nil
        isPaused = false
        activeGitProcess = nil
        if stopRequested {
            summaryMessage = "Stopped. Success: \(successRepositoryCount), Failed: \(failedRepositoryCount)."
            operationStatusText = "Stopped by user."
        } else {
            summaryMessage = "Completed. Success: \(successRepositoryCount), Failed: \(failedRepositoryCount)."
            operationStatusText = "Completed."
        }
        appendLog(summaryMessage)
        currentRepositoryPath = ""
        manualResolutionHintText = ""
    }

    // MARK: - Task building

    private func buildExecutionContexts(repoIndices: [Int]) async -> [RepoExecutionContext] {
        var result: [RepoExecutionContext] = []
        for repoIndex in repoIndices {
            if stopRequested {
                appendLog("Stop requested during task preparation.")
                break
            }
            let repo = repositories[repoIndex]
            appendLog("Preparing context: \(repo.relativePath)")
            do {
                let remote = try await detectSourceRemote(in: repo.repoURL)
                let currentBranch = try await currentBranchName(in: repo.repoURL)
                let branches = try await localBranches(in: repo.repoURL)
                if branches.isEmpty {
                    repositories[repoIndex].state = .failed
                    repositories[repoIndex].detailMessage = "No local branches found."
                    failedRepositoryCount += 1
                    processedRepositoryCount += 1
                    appendLog("Skip \(repo.relativePath): no local branches found.")
                    continue
                }
                let branchesNeedingPull = await branchesNeedingPull(
                    in: repo.repoURL,
                    remote: remote,
                    branches: branches,
                    scope: repo.relativePath
                )
                if branchesNeedingPull.isEmpty {
                    repositories[repoIndex].state = .success
                    repositories[repoIndex].detailMessage = "Already up to date. Skipped."
                    successRepositoryCount += 1
                    processedRepositoryCount += 1
                    appendLog("Skip \(repo.relativePath): all branches are up to date.")
                    continue
                }
                result.append(
                    RepoExecutionContext(
                        repoIndex: repoIndex,
                        remote: remote,
                        originalBranch: currentBranch,
                        localBranches: branchesNeedingPull
                    )
                )
            } catch {
                repositories[repoIndex].state = .failed
                repositories[repoIndex].detailMessage = normalizePreparationError(error.localizedDescription)
                failedRepositoryCount += 1
                processedRepositoryCount += 1
                appendLog("Skip \(repo.relativePath): \(repositories[repoIndex].detailMessage)")
            }
        }
        return result
    }

    private func branchesNeedingPull(
        in repoURL: URL,
        remote: String,
        branches: [String],
        scope: String
    ) async -> [String] {
        if stopRequested { return [] }
        do {
            _ = try await runGitLogged(in: repoURL, arguments: ["fetch", remote, "--prune"])
        } catch {
            appendLog("Fetch failed for \(scope), fallback to pull-all selected branches. \(error.localizedDescription)")
            return branches
        }

        var needingPull: [String] = []
        for branch in branches {
            if stopRequested { break }
            let localRef = "refs/heads/\(branch)"
            let remoteRef = "refs/remotes/\(remote)/\(branch)"
            let remoteExists = (try? await runGit(
                in: repoURL,
                arguments: ["rev-parse", "--verify", "--quiet", remoteRef]
            ).exitCode) == 0

            guard remoteExists else {
                appendLog("Skip branch \(scope) [\(branch)]: remote branch missing.")
                continue
            }

            guard let compare = try? await runGit(
                in: repoURL,
                arguments: ["rev-list", "--left-right", "--count", "\(localRef)...\(remoteRef)"]
            ) else {
                appendLog("Compare failed \(scope) [\(branch)], keep pull for safety.")
                needingPull.append(branch)
                continue
            }

            let parts = compare.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard parts.count >= 2 else {
                appendLog("Unexpected compare result \(scope) [\(branch)], keep pull for safety.")
                needingPull.append(branch)
                continue
            }
            let ahead = Int(parts[0]) ?? 0
            let behind = Int(parts[1]) ?? 0
            if behind > 0 {
                needingPull.append(branch)
            } else {
                let reason = ahead > 0 ? "local ahead" : "up to date"
                appendLog("Skip branch \(scope) [\(branch)]: \(reason).")
            }
        }
        return needingPull
    }

    private func normalizePreparationError(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("no remote found") {
            return "No remote found. Skipped."
        }
        if normalized.contains("detached head") {
            return "Detached HEAD is not supported. Skipped."
        }
        return message
    }

    private func buildTasks(from contexts: [RepoExecutionContext]) -> [RepoUpdateTask] {
        var built: [RepoUpdateTask] = []
        for context in contexts {
            for branch in context.localBranches {
                built.append(
                    RepoUpdateTask(
                        repoIndex: context.repoIndex,
                        kind: .pull(remote: context.remote, branch: branch)
                    )
                )
            }
            built.append(
                RepoUpdateTask(
                    repoIndex: context.repoIndex,
                    kind: .restore(branch: context.originalBranch)
                )
            )
        }
        return built
    }

    private func detectSourceRemote(in repoURL: URL) async throws -> String {
        let remoteOutput = try await runGit(in: repoURL, arguments: ["remote"])
        let remotes = remoteOutput.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if remotes.contains("origin") {
            return "origin"
        }
        guard let first = remotes.first else {
            throw NSError(domain: "RepoUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "No remote found."])
        }
        return first
    }

    private func currentBranchName(in repoURL: URL) async throws -> String {
        let result = try await runGit(in: repoURL, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        let branch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty || branch == "HEAD" {
            throw NSError(domain: "RepoUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Detached HEAD is not supported for bulk update."])
        }
        return branch
    }

    private func localBranches(in repoURL: URL) async throws -> [String] {
        let result = try await runGit(in: repoURL, arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func ensureConflictResolved(repoURL: URL) async throws {
        let unresolved = try await runGit(in: repoURL, arguments: ["ls-files", "-u"])
        if !unresolved.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "RepoUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unresolved conflict files still exist."])
        }
        let mergeHead = try? await runGit(in: repoURL, arguments: ["rev-parse", "-q", "--verify", "MERGE_HEAD"])
        if let mergeHead, !mergeHead.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "RepoUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Merge is not committed yet. Please complete merge commit in SourceTree."])
        }
    }

    private func ensureWorkingTreeClean(repoURL: URL) async throws {
        let status = try await runGit(in: repoURL, arguments: ["status", "--porcelain"])
        let trimmed = status.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let branch = (try? await currentBranchName(in: repoURL)) ?? "unknown"
            let lines = trimmed.split(separator: "\n").map(String.init)
            let previewLimit = 12
            let preview = lines.prefix(previewLimit).joined(separator: "\n")
            let more = lines.count > previewLimit ? "\n... 还有 \(lines.count - previewLimit) 条未展示" : ""
            let detail = """
            仍有未提交改动，请继续在 SourceTree 处理后再继续。
            分支：\(branch)
            变更数：\(lines.count)
            变更明细：
            \(preview)\(more)
            """
            throw NSError(domain: "RepoUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private func isMergeConflictMessage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("conflict")
            || normalized.contains("automatic merge failed")
            || normalized.contains("merge conflict")
    }

    private func isLocalChangeBlockedMessage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("please commit your changes")
            || normalized.contains("stash them")
            || normalized.contains("your local changes")
            || normalized.contains("would be overwritten")
            || normalized.contains("you have unstaged changes")
            || normalized.contains("working tree contains unstaged changes")
    }

    private func makeLocalChangeHint(branch: String, rawMessage: String) -> String {
        let normalized = rawMessage
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = normalized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.isEmpty {
            return "分支 \(branch) 检测到本地改动，请在 SourceTree 处理后继续。"
        }
        let previewLimit = 4
        let preview = lines.prefix(previewLimit).joined(separator: " | ")
        let more = lines.count > previewLimit ? " | ... 还有 \(lines.count - previewLimit) 条" : ""
        return "分支 \(branch) 检测到本地改动：\(preview)\(more)"
    }

    private func openRepositoryInSourceTree(repoURL: URL) {
        let workspace = NSWorkspace.shared
        let bundleIDs = ["com.torusknot.SourceTreeNotMAS", "com.torusknot.SourceTree"]
        let appURL = bundleIDs.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
            ?? {
                let defaultPath = "/Applications/SourceTree.app"
                return FileManager.default.fileExists(atPath: defaultPath) ? URL(fileURLWithPath: defaultPath) : nil
            }()

        guard let appURL else {
            appendLog("SourceTree app not found. Please open SourceTree manually.")
            errorMessage = "SourceTree 未安装或未找到，请手动打开。"
            return
        }

        workspace.open([repoURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error {
                    self.appendLog("Failed to open SourceTree: \(error.localizedDescription)")
                    self.errorMessage = "打开 SourceTree 失败：\(error.localizedDescription)"
                } else {
                    self.appendLog("Opened in SourceTree: \(repoURL.path)")
                }
            }
        }
    }

    // MARK: - Discovery

    private func discoverRepositories(in rootURL: URL) throws -> [URL] {
        var found: [URL] = []
        try walkDirectory(rootURL, found: &found)
        found.sort { $0.path < $1.path }

        var primary: [URL] = []
        for repo in found {
            let nested = primary.contains { repo.path.hasPrefix($0.path + "/") }
            if !nested {
                primary.append(repo)
            }
        }
        return primary
    }

    private func walkDirectory(_ url: URL, found: inout [URL]) throws {
        let name = url.lastPathComponent.lowercased()
        if ignoredDirectoryNames.contains(name) { return }

        var isDir: ObjCBool = false
        let gitPath = url.appendingPathComponent(".git", isDirectory: true)
        if FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir), isDir.boolValue {
            found.append(url)
            return
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try walkDirectory(child, found: &found)
        }
    }

    // MARK: - Git commands

    private func runGitLogged(in folderURL: URL, arguments: [String]) async throws -> RepoUpdateCommandResult {
        let result = try await runGit(in: folderURL, arguments: arguments)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            appendLog(output)
        }
        return result
    }

    private func runGit(in folderURL: URL, arguments: [String]) async throws -> RepoUpdateCommandResult {
        await waitIfPaused()
        if stopRequested {
            throw NSError(domain: "RepoUpdate", code: -999, userInfo: [NSLocalizedDescriptionKey: "Stopped by user."])
        }

        appendLog("git -C \"\(folderURL.path)\" " + arguments.joined(separator: " "))
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", folderURL.path] + arguments
            activeGitProcess = process

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            process.terminationHandler = { process in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let result = RepoUpdateCommandResult(exitCode: process.terminationStatus, output: output)
                Task { @MainActor in
                    self.activeGitProcess = nil
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: result)
                    } else if self.stopRequested && process.terminationStatus == 15 {
                        continuation.resume(throwing: NSError(domain: "RepoUpdate", code: -999, userInfo: [NSLocalizedDescriptionKey: "Stopped by user."]))
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "RepoUpdate",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Git command failed." : output]
                        ))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                self.activeGitProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Logs

    private func appendLog(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " | ")
        let truncated: String
        if normalized.count > maxRuntimeLogLineLength {
            let prefix = normalized.prefix(maxRuntimeLogLineLength)
            truncated = "\(prefix)... [truncated]"
        } else {
            truncated = normalized
        }
        pendingRuntimeLogLines.append("[\(Self.runtimeLogDateFormatter.string(from: Date()))] \(truncated)")
        scheduleRuntimeLogFlush()
    }

    private func scheduleRuntimeLogFlush() {
        guard runtimeLogFlushTask == nil else { return }
        runtimeLogFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: runtimeLogFlushIntervalNanos)
            self.flushRuntimeLog()
            self.runtimeLogFlushTask = nil
        }
    }

    private func flushRuntimeLog() {
        guard !pendingRuntimeLogLines.isEmpty else { return }
        committedRuntimeLogLines.append(contentsOf: pendingRuntimeLogLines)
        pendingRuntimeLogLines.removeAll(keepingCapacity: true)
        if committedRuntimeLogLines.count > maxRuntimeLogLineCount {
            committedRuntimeLogLines.removeFirst(committedRuntimeLogLines.count - maxRuntimeLogLineCount)
        }
        runtimeLog = committedRuntimeLogLines.joined(separator: "\n")
    }

    private func resetLog() {
        runtimeLog = ""
        pendingRuntimeLogLines.removeAll(keepingCapacity: false)
        committedRuntimeLogLines.removeAll(keepingCapacity: false)
        runtimeLogFlushTask?.cancel()
        runtimeLogFlushTask = nil
    }

    private func waitIfPaused() async {
        while isRunning && isPaused && !stopRequested {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
