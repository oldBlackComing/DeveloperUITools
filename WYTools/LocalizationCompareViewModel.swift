//
//  LocalizationCompareViewModel.swift
//  WYTools
//

import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class LocalizationCompareViewModel {
    var selectedFolderPath: String = ""
    var isScanning = false
    var errorMessage: String?
    var scanResult: LocalizationCompareScanResult?
    /// Languages (codes) included in the detailed list; default all after scan.
    var includedLanguageCodes: Set<String> = []

    var debugTraceKey: String = "10 consecutive works score above 85"
    var debugTraceOutput: String = ""
    var isTracingKey = false

    private var securityScopedFolderURL: URL?
    private var isAccessingSecurityScopedResource = false

    func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Xcode project folder (repository or .xcodeproj parent)."
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        stopSecurityScopedAccessIfNeeded()

        securityScopedFolderURL = url
        if url.startAccessingSecurityScopedResource() {
            isAccessingSecurityScopedResource = true
        }

        selectedFolderPath = url.path
        scanResult = nil
        errorMessage = nil
        includedLanguageCodes = []
    }

    func scan() async {
        guard let root = securityScopedFolderURL else {
            errorMessage = "Choose a folder first."
            return
        }

        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        do {
            let result = try await LocalizationCompareScanner.scan(projectRoot: root)
            scanResult = result
            includedLanguageCodes = Set(result.languages.map(\.languageCode))
        } catch {
            scanResult = nil
            includedLanguageCodes = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearSelection() {
        stopSecurityScopedAccessIfNeeded()
        securityScopedFolderURL = nil
        selectedFolderPath = ""
        scanResult = nil
        errorMessage = nil
        includedLanguageCodes = []
    }

    func setIncluded(_ code: String, isOn: Bool) {
        if isOn {
            includedLanguageCodes.insert(code)
        } else {
            includedLanguageCodes.remove(code)
        }
    }

    func selectAllLanguages() {
        guard let scanResult else { return }
        includedLanguageCodes = Set(scanResult.languages.map(\.languageCode))
    }

    func deselectAllLanguages() {
        includedLanguageCodes = []
    }

    /// Console-style trace for one entry key (same logic as `LocalizationCompareScanner.debugComparisonTrace`).
    func runKeyTrace() async {
        guard let root = securityScopedFolderURL else {
            debugTraceOutput = "Choose a folder first."
            return
        }
        let key = debugTraceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            debugTraceOutput = "Enter a non-empty key."
            return
        }
        isTracingKey = true
        debugTraceOutput = ""
        defer { isTracingKey = false }
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try LocalizationCompareScanner.debugComparisonTrace(projectRoot: root, entryKey: key)
            }.value
            debugTraceOutput = text
        } catch {
            debugTraceOutput = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func stopSecurityScopedAccessIfNeeded() {
        if let url = securityScopedFolderURL, isAccessingSecurityScopedResource {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
        securityScopedFolderURL = nil
    }
}
