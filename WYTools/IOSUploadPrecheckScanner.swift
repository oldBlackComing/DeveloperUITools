//
//  IOSUploadPrecheckScanner.swift
//  WYTools
//

import CoreGraphics
import Foundation
import ImageIO

enum IOSUploadPrecheckSeverity: String, Sendable {
    case error
    case warning
    case info
}

struct IOSUploadPrecheckIssue: Identifiable, Sendable {
    let id = UUID()
    let severity: IOSUploadPrecheckSeverity
    let title: String
    let detail: String
}

struct IOSUploadPrecheckResult: Sendable {
    let startedAt: Date
    let finishedAt: Date
    let projectPath: String
    let scheme: String
    let archivePath: String?
    let exportPath: String?
    let issues: [IOSUploadPrecheckIssue]
    let rawLog: String

    var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }
}

enum IOSUploadPrecheckError: LocalizedError {
    case noProjectFound
    case noWorkspaceOrProject
    case noSchemeFound
    case commandFailed(command: String, output: String)
    case archiveNotFound

    var errorDescription: String? {
        switch self {
        case .noProjectFound:
            return "在所选目录中未发现 iOS 工程（.xcodeproj / .xcworkspace）。"
        case .noWorkspaceOrProject:
            return "无法选择可用工程文件（.xcworkspace / .xcodeproj）。"
        case .noSchemeFound:
            return "未发现可用的共享 Scheme，请手动输入 Scheme。"
        case .commandFailed(let command, let output):
            let brief: String
            if output.count > 6_000 {
                let head = String(output.prefix(3_000))
                let tail = String(output.suffix(3_000))
                brief = "\(head)\n\n…（错误输出已截断，共 \(output.count) 字符）…\n\n\(tail)"
            } else {
                brief = output
            }
            return "命令执行失败：\(command)\n\(brief)"
        case .archiveNotFound:
            return "Archive 过程结束，但未找到 .xcarchive 产物。"
        }
    }
}

enum IOSUploadPrecheckScanner {
    enum StepID: String {
        case detectProject
        case staticChecks
        case archive
        case archiveArtifactChecks
        case export
        case finished
    }

    struct Input: Sendable {
        let rootFolder: URL
        let preferredScheme: String
        let configuration: String
        let shouldExportArchive: Bool
        let allowProvisioningUpdates: Bool
    }

    private struct ProjectSelection {
        let typeFlag: String
        let path: URL
    }

    static func run(
        input: Input,
        onStatus: (@Sendable (_ status: String) -> Void)? = nil,
        onStep: (@Sendable (_ stepID: String, _ state: IOSUploadPrecheckTaskState, _ message: String) -> Void)? = nil
    ) async throws -> IOSUploadPrecheckResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(input: input, onStatus: onStatus, onStep: onStep)
        }.value
    }

    private static func runSync(
        input: Input,
        onStatus: (@Sendable (_ status: String) -> Void)? = nil,
        onStep: (@Sendable (_ stepID: String, _ state: IOSUploadPrecheckTaskState, _ message: String) -> Void)? = nil
    ) throws -> IOSUploadPrecheckResult {
        let startedAt = Date()
        var logs: [String] = []
        var issues: [IOSUploadPrecheckIssue] = []

        onStatus?("正在识别工程与 Scheme…")
        onStep?(StepID.detectProject.rawValue, .running, "正在识别工程与 Scheme…")
        let selection: ProjectSelection
        let scheme: String
        do {
            selection = try pickProjectOrWorkspace(in: input.rootFolder)
            scheme = try resolveScheme(selection: selection, preferred: input.preferredScheme)
            onStep?(StepID.detectProject.rawValue, .success, "已识别：\(selection.path.lastPathComponent) / \(scheme)")
        } catch {
            onStep?(StepID.detectProject.rawValue, .failed, "识别失败")
            throw error
        }
        logs.append("[信息] 已选择 \(selection.typeFlag): \(selection.path.path)")
        logs.append("[信息] 已选择 Scheme: \(scheme)")

        onStatus?("正在执行静态规则检查（图标、Info.plist、签名等）…")
        onStep?(StepID.staticChecks.rawValue, .running, "图标 / Info.plist / 签名 / Entitlements")
        let staticIssues: [IOSUploadPrecheckIssue]
        do {
            staticIssues = try runStaticChecks(
                rootFolder: input.rootFolder,
                selection: selection,
                scheme: scheme
            )
            onStep?(StepID.staticChecks.rawValue, .success, "静态检查完成，发现 \(staticIssues.count) 项提示")
        } catch {
            onStep?(StepID.staticChecks.rawValue, .failed, "静态检查失败")
            throw error
        }
        issues.append(contentsOf: staticIssues)

        let archivePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("WYTools-\(Int(Date().timeIntervalSince1970)).xcarchive")
        onStatus?("正在执行 Archive（xcodebuild clean archive）…")
        onStep?(StepID.archive.rawValue, .running, "执行 xcodebuild clean archive")
        let archiveResult: (output: String, status: Int32)
        do {
            archiveResult = try runXcodebuildArchive(
                selection: selection,
                scheme: scheme,
                configuration: input.configuration,
                archivePath: archivePath,
                allowProvisioningUpdates: input.allowProvisioningUpdates
            )
            onStep?(StepID.archive.rawValue, .success, "Archive 执行完成")
        } catch {
            onStep?(StepID.archive.rawValue, .failed, "Archive 执行失败")
            throw error
        }
        logs.append(archiveResult.output)
        issues.append(contentsOf: classifyBuildOutput(archiveResult.output))

        guard FileManager.default.fileExists(atPath: archivePath.path) else {
            onStep?(StepID.archive.rawValue, .failed, "未找到 .xcarchive 产物")
            throw IOSUploadPrecheckError.archiveNotFound
        }
        onStatus?("正在校验归档产物结构（.xcarchive）…")
        onStep?(StepID.archiveArtifactChecks.rawValue, .running, "检查 App 包、Info.plist、dSYM、provisioning")
        issues.append(contentsOf: runArchiveProductChecks(archivePath: archivePath))
        onStep?(StepID.archiveArtifactChecks.rawValue, .success, "归档产物校验完成")

        var exportPathString: String?
        if input.shouldExportArchive {
            let exportDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("WYTools-export-\(Int(Date().timeIntervalSince1970))")
            let plistURL = try createExportOptionsPlist(inside: exportDir)
            onStatus?("正在执行 Export（xcodebuild -exportArchive）…")
            onStep?(StepID.export.rawValue, .running, "执行 xcodebuild -exportArchive")
            do {
                let exportResult = try runXcodebuildExport(
                    archivePath: archivePath,
                    exportPath: exportDir,
                    exportOptionsPlist: plistURL
                )
                logs.append(exportResult.output)
                issues.append(contentsOf: classifyBuildOutput(exportResult.output))
                exportPathString = exportDir.path
                onStep?(StepID.export.rawValue, .success, "Export 执行完成")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logs.append("[警告] Export 失败：\(message)")
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "Export 校验失败（不影响已完成的 Archive 结果）",
                        detail: message
                    )
                )
                onStep?(StepID.export.rawValue, .failed, "Export 失败，已记录详情")
            }
        } else {
            onStep?(StepID.export.rawValue, .skipped, "已跳过 Export（你关闭了导出选项）")
        }

        let finishedAt = Date()
        onStatus?("预检完成。")
        onStep?(StepID.finished.rawValue, .success, "已生成完整预检报告")
        return IOSUploadPrecheckResult(
            startedAt: startedAt,
            finishedAt: finishedAt,
            projectPath: selection.path.path,
            scheme: scheme,
            archivePath: archivePath.path,
            exportPath: exportPathString,
            issues: deduplicateIssues(issues),
            rawLog: trimLargeText(logs.joined(separator: "\n\n"), maxCharacters: 40_000)
        )
    }

    private static func pickProjectOrWorkspace(in root: URL) throws -> ProjectSelection {
        let workspaces = try findPaths(withExtension: "xcworkspace", under: root)
            .filter { !$0.path.contains("/Pods/") }
        if let workspace = workspaces.first {
            return ProjectSelection(typeFlag: "-workspace", path: workspace)
        }

        let projects = try findPaths(withExtension: "xcodeproj", under: root)
            .filter { !$0.path.contains("/Pods/") }
        if let project = projects.first {
            return ProjectSelection(typeFlag: "-project", path: project)
        }
        throw IOSUploadPrecheckError.noProjectFound
    }

    private static func resolveScheme(selection: ProjectSelection, preferred: String) throws -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let output = try runProcess(
            launchPath: "/usr/bin/xcodebuild",
            arguments: [selection.typeFlag, selection.path.path, "-list", "-json"],
            currentDirectory: selection.path.deletingLastPathComponent()
        )
        guard
            let data = output.output.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw IOSUploadPrecheckError.noSchemeFound
        }

        let key = selection.typeFlag == "-workspace" ? "workspace" : "project"
        if
            let payload = obj[key] as? [String: Any],
            let schemes = payload["schemes"] as? [String],
            let first = schemes.first
        {
            return first
        }
        throw IOSUploadPrecheckError.noSchemeFound
    }

    private static func runStaticChecks(
        rootFolder: URL,
        selection: ProjectSelection,
        scheme: String
    ) throws -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []

        let buildSettings = try runProcess(
            launchPath: "/usr/bin/xcodebuild",
            arguments: [
                selection.typeFlag, selection.path.path,
                "-scheme", scheme,
                "-showBuildSettings",
            ],
            currentDirectory: selection.path.deletingLastPathComponent()
        )
        let fieldsByTarget = extractBuildSettingsByTarget(buildSettings.output)
        var validatedIconSetPaths = Set<String>()
        if fieldsByTarget.isEmpty {
            let fallbackFields = extractBuildSettingFields(buildSettings.output)
            issues.append(contentsOf: validateBuildSettings(fields: fallbackFields, targetName: "未知目标"))
            issues.append(contentsOf: validateInfoPlistChecks(fields: fallbackFields, projectDirectory: selection.path.deletingLastPathComponent(), targetName: "未知目标"))
            issues.append(contentsOf: validateEntitlementsChecks(fields: fallbackFields, projectDirectory: selection.path.deletingLastPathComponent(), targetName: "未知目标"))
            issues.append(
                contentsOf: validateTargetAppIconChecks(
                    fields: fallbackFields,
                    targetName: "未知目标",
                    rootFolder: rootFolder,
                    projectDirectory: selection.path.deletingLastPathComponent(),
                    validatedIconSetPaths: &validatedIconSetPaths
                )
            )
        } else {
            for (target, fields) in fieldsByTarget.sorted(by: { $0.key < $1.key }) {
                guard shouldValidateTarget(fields: fields) else { continue }
                issues.append(contentsOf: validateBuildSettings(fields: fields, targetName: target))
                issues.append(contentsOf: validateInfoPlistChecks(fields: fields, projectDirectory: selection.path.deletingLastPathComponent(), targetName: target))
                issues.append(contentsOf: validateEntitlementsChecks(fields: fields, projectDirectory: selection.path.deletingLastPathComponent(), targetName: target))
                issues.append(
                    contentsOf: validateTargetAppIconChecks(
                        fields: fields,
                        targetName: target,
                        rootFolder: rootFolder,
                        projectDirectory: selection.path.deletingLastPathComponent(),
                        validatedIconSetPaths: &validatedIconSetPaths
                    )
                )
            }
        }

        return issues
    }

    private static func validateTargetAppIconChecks(
        fields: [String: String],
        targetName: String,
        rootFolder: URL,
        projectDirectory: URL,
        validatedIconSetPaths: inout Set<String>
    ) -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []
        let iconName = fields["ASSETCATALOG_COMPILER_APPICON_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !iconName.isEmpty else { return issues }

        if iconName.contains("$(") || iconName.contains("${") {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .info,
                    title: "[\(targetName)] AppIcon 名称为变量表达式，已跳过静态图标定位",
                    detail: "当前值：\(iconName)。建议使用固定名称以获得更精确校验。"
                )
            )
            return issues
        }

        let srcRootRaw = fields["SRCROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? projectDirectory.path
        let srcRoot = URL(fileURLWithPath: srcRootRaw)
        let iconSetName = "\(iconName).appiconset"
        let foundSets = (try? findDirectories(named: iconSetName, under: srcRoot)) ?? []
        let candidateSets = foundSets.filter {
            !isIgnoredResourcePath($0) && $0.path.hasPrefix(rootFolder.path)
        }

        if candidateSets.isEmpty {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "[\(targetName)] 未找到目标 AppIcon 资源集",
                    detail: "按 target 配置应存在 `\(iconSetName)`，但在源码目录中未定位到有效路径。"
                )
            )
            return issues
        }

        for setURL in candidateSets {
            if validatedIconSetPaths.insert(setURL.path).inserted {
                if let checked = try? validateAppIconSet(at: setURL) {
                    issues.append(contentsOf: checked)
                } else {
                    issues.append(
                        IOSUploadPrecheckIssue(
                            severity: .warning,
                            title: "[\(targetName)] AppIcon 校验失败",
                            detail: "读取图标资源时出错：\(setURL.path)"
                        )
                    )
                }
            }
        }
        return issues
    }

    private static func validateBuildSettings(fields: [String: String], targetName: String) -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []

        let requiredKeys = [
            "PRODUCT_BUNDLE_IDENTIFIER",
            "MARKETING_VERSION",
            "CURRENT_PROJECT_VERSION",
            "INFOPLIST_FILE",
            "ASSETCATALOG_COMPILER_APPICON_NAME",
        ]
        for key in requiredKeys {
            let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "[\(targetName)] 缺少构建配置：\(key)",
                        detail: "该配置缺失可能导致 archive/export 或商店校验失败。"
                    )
                )
            }
        }

        if (fields["DEVELOPMENT_TEAM"] ?? "").isEmpty {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] DEVELOPMENT_TEAM 为空",
                    detail: "用于 iOS 分发归档时，自动签名可能失败。"
                )
            )
        }

        if let bundleID = fields["PRODUCT_BUNDLE_IDENTIFIER"], !bundleID.isEmpty,
           !isValidBundleIdentifier(bundleID)
        {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] PRODUCT_BUNDLE_IDENTIFIER 格式疑似无效",
                    detail: "当前值：\(bundleID)"
                )
            )
        }

        if let marketingVersion = fields["MARKETING_VERSION"], !marketingVersion.isEmpty,
           !isValidMarketingVersion(marketingVersion)
        {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] MARKETING_VERSION 格式可能不合法",
                    detail: "建议格式为 1.0 或 1.2.3 这类纯数字分段。当前值：\(marketingVersion)"
                )
            )
        }

        if let projectVersion = fields["CURRENT_PROJECT_VERSION"], !projectVersion.isEmpty,
           !isValidBuildNumber(projectVersion)
        {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] CURRENT_PROJECT_VERSION 格式可能不合法",
                    detail: "当前构建号：\(projectVersion)"
                )
            )
        }

        if let deployment = fields["IPHONEOS_DEPLOYMENT_TARGET"],
           let version = Double(deployment),
           version < 12.0
        {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .info,
                    title: "[\(targetName)] iOS 最低版本偏低",
                    detail: "当前 IPHONEOS_DEPLOYMENT_TARGET 为 \(deployment)，建议确认对现代 iOS 版本的兼容性。"
                )
            )
        }

        let codeSignStyle = fields["CODE_SIGN_STYLE"]?.lowercased() ?? ""
        if codeSignStyle == "manual" {
            let profile = fields["PROVISIONING_PROFILE_SPECIFIER"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if profile.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "[\(targetName)] 手动签名缺少 Provisioning Profile",
                        detail: "CODE_SIGN_STYLE 为 Manual，但 PROVISIONING_PROFILE_SPECIFIER 为空。"
                    )
                )
            }
        }
        return issues
    }

    private static func shouldValidateTarget(fields: [String: String]) -> Bool {
        let sdkName = (fields["SDK_NAME"] ?? "").lowercased()
        let supported = (fields["SUPPORTED_PLATFORMS"] ?? "").lowercased()
        if sdkName.contains("iphone") || supported.contains("iphoneos") || supported.contains("iphonesimulator") {
            return true
        }
        return false
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isValidMarketingVersion(_ value: String) -> Bool {
        let pattern = #"^\d+(\.\d+){0,2}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isValidBuildNumber(_ value: String) -> Bool {
        let pattern = #"^\d+(\.\d+)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func extractBuildSettingFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let textLine = String(line)
            guard let range = textLine.range(of: " = ") else { continue }
            let key = String(textLine[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(textLine[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func extractBuildSettingsByTarget(_ text: String) -> [String: [String: String]] {
        var output: [String: [String: String]] = [:]
        var currentTarget = "Unknown"

        for line in text.split(whereSeparator: \.isNewline) {
            let textLine = String(line)
            let prefix = "Build settings for action build and target "
            if textLine.hasPrefix(prefix), let range = textLine.range(of: ":") {
                let target = String(textLine[prefix.endIndex ..< range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                currentTarget = target.isEmpty ? "Unknown" : target
                if output[currentTarget] == nil {
                    output[currentTarget] = [:]
                }
                continue
            }

            guard let eqRange = textLine.range(of: " = ") else { continue }
            let key = String(textLine[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(textLine[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            output[currentTarget, default: [:]][key] = value
        }
        return output
    }

    private static func validateInfoPlistChecks(
        fields: [String: String],
        projectDirectory: URL,
        targetName: String
    ) -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []
        let infoPlistRaw = fields["INFOPLIST_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !infoPlistRaw.isEmpty else { return issues }

        let resolvedPath = resolveBuildSettingPath(infoPlistRaw, fields: fields, projectDirectory: projectDirectory)
        guard FileManager.default.fileExists(atPath: resolvedPath.path) else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "[\(targetName)] INFOPLIST_FILE 路径不存在",
                    detail: "配置路径不存在：\(resolvedPath.path)"
                ),
            ]
        }

        guard let plist = NSDictionary(contentsOf: resolvedPath) as? [String: Any] else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "[\(targetName)] Info.plist 解析失败",
                    detail: "无法解析：\(resolvedPath.path)"
                ),
            ]
        }

        let shortVersion = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if shortVersion.isEmpty {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] 缺少 CFBundleShortVersionString",
                    detail: "Info.plist 应提供非空营销版本号（Marketing Version）。"
                )
            )
        }

        let bundleVersion = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleVersion.isEmpty {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] 缺少 CFBundleVersion",
                    detail: "Info.plist 应提供非空构建号（Build Number）。"
                )
            )
        }

        let displayName = (plist["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleName = (plist["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if displayName.isEmpty && bundleName.isEmpty {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] 应用名称为空",
                    detail: "CFBundleDisplayName 与 CFBundleName 均未设置。"
                )
            )
        }

        for key in privacyUsageKeys {
            if let value = plist[key] as? String, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "[\(targetName)] 隐私权限文案为空",
                        detail: "\(key) 已存在，但描述文案为空。"
                    )
                )
            }
        }

        return issues
    }

    private static let privacyUsageKeys: [String] = [
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
        "NSLocationWhenInUseUsageDescription",
        "NSLocationAlwaysAndWhenInUseUsageDescription",
        "NSUserTrackingUsageDescription",
        "NSBluetoothAlwaysUsageDescription",
        "NSContactsUsageDescription",
        "NSCalendarsUsageDescription",
        "NSRemindersUsageDescription",
        "NSFaceIDUsageDescription",
        "NSSpeechRecognitionUsageDescription",
        "NSMotionUsageDescription",
    ]

    private static func validateEntitlementsChecks(
        fields: [String: String],
        projectDirectory: URL,
        targetName: String
    ) -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []
        let entitlementsRaw = fields["CODE_SIGN_ENTITLEMENTS"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !entitlementsRaw.isEmpty else { return issues }

        let resolvedPath = resolveBuildSettingPath(entitlementsRaw, fields: fields, projectDirectory: projectDirectory)
        guard FileManager.default.fileExists(atPath: resolvedPath.path) else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "[\(targetName)] CODE_SIGN_ENTITLEMENTS 文件不存在",
                    detail: "配置路径不存在：\(resolvedPath.path)"
                ),
            ]
        }

        guard let plist = NSDictionary(contentsOf: resolvedPath) as? [String: Any] else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "[\(targetName)] Entitlements 解析失败",
                    detail: "无法解析：\(resolvedPath.path)"
                ),
            ]
        }

        if let aps = plist["aps-environment"] as? String,
           aps != "development", aps != "production"
        {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "[\(targetName)] aps-environment 配置无效",
                    detail: "应为 `development` 或 `production`，当前为 `\(aps)`。"
                )
            )
        }

        if let groups = plist["com.apple.security.application-groups"] as? [String] {
            for group in groups where !group.hasPrefix("group.") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "[\(targetName)] App Group 格式无效",
                        detail: "Application Group 应以 `group.` 开头：\(group)"
                    )
                )
            }
        }

        if let domains = plist["com.apple.developer.associated-domains"] as? [String] {
            for domain in domains {
                let validPrefixes = ["applinks:", "webcredentials:", "activitycontinuation:", "appclips:"]
                if !validPrefixes.contains(where: { domain.hasPrefix($0) }) {
                    issues.append(
                        IOSUploadPrecheckIssue(
                            severity: .warning,
                            title: "[\(targetName)] Associated Domains 条目格式无效",
                            detail: "不支持的条目格式：\(domain)"
                        )
                    )
                }
            }
        }

        return issues
    }

    private static func resolveBuildSettingPath(_ raw: String, fields: [String: String], projectDirectory: URL) -> URL {
        let sourceRoot = fields["SRCROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? projectDirectory.path
        var expanded = raw
        expanded = expanded.replacingOccurrences(of: "$(SRCROOT)", with: sourceRoot)
        expanded = expanded.replacingOccurrences(of: "${SRCROOT}", with: sourceRoot)

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: sourceRoot).appendingPathComponent(expanded)
    }

    private static func validateAppIconSet(at appIconSetURL: URL) throws -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []
        let contentsJSON = appIconSetURL.appendingPathComponent("Contents.json")

        guard FileManager.default.fileExists(atPath: contentsJSON.path) else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "缺少 AppIcon 的 Contents.json",
                    detail: "文件不存在：\(contentsJSON.path)"
                ),
            ]
        }

        let data = try Data(contentsOf: contentsJSON)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let images = object["images"] as? [[String: Any]]
        else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "AppIcon 的 Contents.json 无法解析",
                    detail: "无法从 \(contentsJSON.path) 解析 `images` 数组。"
                ),
            ]
        }

        let storeIconCandidates = images.filter { row in
            let size = (row["size"] as? String)?.lowercased() ?? ""
            let idiom = (row["idiom"] as? String)?.lowercased() ?? ""
            return size == "1024x1024" && (idiom == "ios-marketing" || idiom == "universal")
        }

        if storeIconCandidates.isEmpty {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "缺少 1024 的 App Store 图标槽位",
                    detail: "在 \(contentsJSON.path) 中未找到 iOS marketing icon（1024x1024）。"
                )
            )
            return issues
        }

        for candidate in storeIconCandidates {
            let filename = (candidate["filename"] as? String) ?? ""
            if filename.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .error,
                        title: "1024 图标槽位未配置文件名",
                        detail: "已存在 1024x1024 槽位，但在 \(contentsJSON.path) 中未填写 filename。"
                    )
                )
                continue
            }

            let imageURL = appIconSetURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .error,
                        title: "1024 图标文件缺失",
                        detail: "1024 槽位对应文件不存在：\(imageURL.path)"
                    )
                )
                continue
            }
            issues.append(contentsOf: validateMarketingIcon(at: imageURL))
        }

        return issues
    }

    private static func validateMarketingIcon(at fileURL: URL) -> [IOSUploadPrecheckIssue] {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return [
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "无法读取 App Store 图标",
                    detail: "打开失败：\(fileURL.path)"
                ),
            ]
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }

        var issues: [IOSUploadPrecheckIssue] = []
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if width != 1024 || height != 1024 {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "App Store 图标尺寸不正确",
                    detail: "期望 1024x1024，实际 \(width)x\(height)（\(fileURL.lastPathComponent)）。"
                )
            )
        }

        let hasAlphaChannel: Bool = {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast:
                return false
            default:
                return true
            }
        }()
        if hasAlphaChannel {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "App Store 图标包含透明通道（alpha）",
                    detail: "商店校验要求 marketing icon 不可带透明通道。文件：\(fileURL.path)"
                )
            )
        }

        return issues
    }

    private static func runXcodebuildArchive(
        selection: ProjectSelection,
        scheme: String,
        configuration: String,
        archivePath: URL,
        allowProvisioningUpdates: Bool
    ) throws -> (output: String, status: Int32) {
        var args: [String] = [
            selection.typeFlag, selection.path.path,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", "generic/platform=iOS",
            "-archivePath", archivePath.path,
            "clean",
            "archive",
        ]
        if allowProvisioningUpdates {
            args.append("-allowProvisioningUpdates")
        }
        let result = try runProcess(
            launchPath: "/usr/bin/xcodebuild",
            arguments: args,
            currentDirectory: selection.path.deletingLastPathComponent()
        )
        if result.status != 0 {
            throw IOSUploadPrecheckError.commandFailed(
                command: "/usr/bin/xcodebuild \(args.joined(separator: " "))",
                output: trimLargeText(result.output, maxCharacters: 80_000)
            )
        }
        return result
    }

    private static func runXcodebuildExport(
        archivePath: URL,
        exportPath: URL,
        exportOptionsPlist: URL
    ) throws -> (output: String, status: Int32) {
        let args = [
            "-exportArchive",
            "-archivePath", archivePath.path,
            "-exportPath", exportPath.path,
            "-exportOptionsPlist", exportOptionsPlist.path,
        ]
        let result = try runProcess(
            launchPath: "/usr/bin/xcodebuild",
            arguments: args,
            currentDirectory: exportPath
        )
        if result.status != 0 {
            throw IOSUploadPrecheckError.commandFailed(
                command: "/usr/bin/xcodebuild \(args.joined(separator: " "))",
                output: trimLargeText(result.output, maxCharacters: 80_000)
            )
        }
        return result
    }

    private static func createExportOptionsPlist(inside exportDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let plistURL = exportDirectory.appendingPathComponent("ExportOptions.plist")
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>method</key>
            <string>development</string>
            <key>signingStyle</key>
            <string>automatic</string>
            <key>destination</key>
            <string>export</string>
            <key>stripSwiftSymbols</key>
            <true/>
            <key>compileBitcode</key>
            <false/>
        </dict>
        </plist>
        """
        try content.write(to: plistURL, atomically: true, encoding: .utf8)
        return plistURL
    }

    private static func runArchiveProductChecks(archivePath: URL) -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []
        let archiveInfo = archivePath.appendingPathComponent("Info.plist")
        if !FileManager.default.fileExists(atPath: archiveInfo.path) {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "归档缺少 Info.plist",
                    detail: "预期文件不存在：\(archiveInfo.path)"
                )
            )
            return issues
        }

        if let archivePlist = NSDictionary(contentsOf: archiveInfo) as? [String: Any],
           let appProps = archivePlist["ApplicationProperties"] as? [String: Any]
        {
            let bundleID = (appProps["CFBundleIdentifier"] as? String) ?? ""
            if bundleID.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "归档缺少 CFBundleIdentifier",
                        detail: "ApplicationProperties.CFBundleIdentifier 为空。"
                    )
                )
            }

            let shortVersion = (appProps["CFBundleShortVersionString"] as? String) ?? ""
            if shortVersion.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "归档缺少 CFBundleShortVersionString",
                        detail: "ApplicationProperties.CFBundleShortVersionString 为空。"
                    )
                )
            }

            let bundleVersion = (appProps["CFBundleVersion"] as? String) ?? ""
            if bundleVersion.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "归档缺少 CFBundleVersion",
                        detail: "ApplicationProperties.CFBundleVersion 为空。"
                    )
                )
            }
        }

        let productsApplications = archivePath.appendingPathComponent("Products/Applications")
        let appBundle = findFirstAppBundle(in: productsApplications)
        guard let appBundle else {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .error,
                    title: "归档中缺少 .app 包",
                    detail: "在 \(productsApplications.path) 未找到 .app 包。"
                )
            )
            return issues
        }

        let appInfoURL = appBundle.appendingPathComponent("Info.plist")
        if let appInfo = NSDictionary(contentsOf: appInfoURL) as? [String: Any] {
            let executable = (appInfo["CFBundleExecutable"] as? String) ?? ""
            if executable.isEmpty {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .error,
                        title: "CFBundleExecutable 为空",
                        detail: "App 的 Info.plist 未定义 CFBundleExecutable。"
                    )
                )
            } else {
                let binaryURL = appBundle.appendingPathComponent(executable)
                if !FileManager.default.fileExists(atPath: binaryURL.path) {
                    issues.append(
                        IOSUploadPrecheckIssue(
                            severity: .error,
                            title: "归档中缺少可执行文件",
                            detail: "未找到预期二进制：\(binaryURL.path)"
                        )
                    )
                }
            }

            if let minOS = appInfo["MinimumOSVersion"] as? String,
               let minValue = Double(minOS),
               minValue < 12.0
            {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .info,
                        title: "归档产物 MinimumOSVersion 偏低",
                        detail: "MinimumOSVersion 为 \(minOS)。"
                    )
                )
            }
        } else {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "归档内 App Info.plist 不可读",
                    detail: "无法解析：\(appInfoURL.path)"
                )
            )
        }

        let provisionURL = appBundle.appendingPathComponent("embedded.mobileprovision")
        if !FileManager.default.fileExists(atPath: provisionURL.path) {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "缺少 embedded.mobileprovision",
                    detail: "归档 App 中未包含 provisioning profile：\(provisionURL.path)"
                )
            )
        }

        let dsymsPath = archivePath.appendingPathComponent("dSYMs")
        if !FileManager.default.fileExists(atPath: dsymsPath.path) {
            issues.append(
                IOSUploadPrecheckIssue(
                    severity: .warning,
                    title: "归档中缺少 dSYMs 目录",
                    detail: "未找到预期调试符号目录：\(dsymsPath.path)"
                )
            )
        }

        return issues
    }

    private static func findFirstAppBundle(in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.first(where: { $0.pathExtension.lowercased() == "app" })
    }

    private static func classifyBuildOutput(_ text: String) -> [IOSUploadPrecheckIssue] {
        var issues: [IOSUploadPrecheckIssue] = []
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        for line in lines {
            let lower = line.lowercased()

            if lower.contains("error:") || lower.contains("** archive failed **") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .error,
                        title: "构建错误",
                        detail: line
                    )
                )
            } else if lower.contains("warning:") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "构建警告",
                        detail: line
                    )
                )
            }

            if lower.contains("invalid app store icon") || lower.contains("alpha channel") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .error,
                        title: "App Store 图标校验问题",
                        detail: line
                    )
                )
            }
            if lower.contains("provisioning profile") || lower.contains("code signing") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "签名配置问题",
                        detail: line
                    )
                )
            }
            if lower.contains("cfbundleversion") || lower.contains("marketing_version") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "版本号/构建号元数据问题",
                        detail: line
                    )
                )
            }

            if lower.contains("itms-") || lower.contains("asset validation failed") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .error,
                        title: "商店风格校验问题（ITMS）",
                        detail: line
                    )
                )
            }
            if lower.contains("missing info.plist value") || lower.contains("invalid info.plist") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "Info.plist 元数据问题",
                        detail: line
                    )
                )
            }
            if lower.contains("bundle identifier") && lower.contains("invalid") {
                issues.append(
                    IOSUploadPrecheckIssue(
                        severity: .warning,
                        title: "Bundle Identifier 问题",
                        detail: line
                    )
                )
            }
        }
        return issues
    }

    private static func deduplicateIssues(_ issues: [IOSUploadPrecheckIssue]) -> [IOSUploadPrecheckIssue] {
        var seen: Set<String> = []
        var output: [IOSUploadPrecheckIssue] = []
        for issue in issues {
            let key = "\(issue.severity.rawValue)|\(issue.title)|\(issue.detail)"
            if seen.insert(key).inserted {
                output.append(issue)
            }
        }
        return output
    }

    private static func trimLargeText(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 120 else { return text }
        let headCount = maxCharacters / 2
        let tailCount = maxCharacters - headCount
        let head = String(text.prefix(headCount))
        let tail = String(text.suffix(tailCount))
        return "\(head)\n\n…（日志已截断，共 \(text.count) 字符）…\n\n\(tail)"
    }

    private static func isIgnoredResourcePath(_ url: URL) -> Bool {
        let path = url.path
        let ignoredMarkers = [
            "/DerivedData/",
            "/SourcePackages/",
            "/checkouts/",
            "/Pods/",
            "/Carthage/",
            "/.build/",
            "/Build/",
        ]
        return ignoredMarkers.contains { path.contains($0) }
    }

    private static func runProcess(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WYTools-precheck-process-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: logURL)
        process.standardOutput = writer
        process.standardError = writer

        try process.run()
        process.waitUntilExit()
        try? writer.close()

        let merged = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: logURL)
        return (trimLargeText(merged, maxCharacters: 200_000), process.terminationStatus)
    }

    private static func findPaths(withExtension extensionName: String, under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var output: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == extensionName.lowercased(),
               !isIgnoredResourcePath(url)
            {
                output.append(url)
            }
        }
        return output
    }

    private static func findDirectories(named name: String, under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var output: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == name {
            if isIgnoredResourcePath(url) { continue }
            var isDirectory = ObjCBool(false)
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                output.append(url)
            }
        }
        return output
    }
}
