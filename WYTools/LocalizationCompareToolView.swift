//
//  LocalizationCompareToolView.swift
//  WYTools
//

import SwiftUI

struct LocalizationCompareToolView: View {
    @State private var viewModel = LocalizationCompareViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Each locale lists keys that exist in English `.strings` but are missing in that locale’s `.strings`. Only files outside `Pods/` are scanned (main app + local modules such as CMPurchaseIOS). If there is no English `.strings`, String Catalog is used instead."
                )
                .font(.subheadline)
                .foregroundStyle(DiffToolTheme.muted)

                HStack(spacing: 12) {
                    Button("Choose Folder…") {
                        viewModel.pickProjectFolder()
                    }
                    .buttonStyle(DiffToolPrimaryButtonStyle())

                    Button("Scan") {
                        Task { await viewModel.scan() }
                    }
                    .buttonStyle(DiffToolSecondaryButtonStyle())
                    .disabled(viewModel.selectedFolderPath.isEmpty || viewModel.isScanning)

                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .tint(DiffToolTheme.accent)
                .foregroundStyle(DiffToolTheme.text)

                if !viewModel.selectedFolderPath.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        Text(viewModel.selectedFolderPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DiffToolTheme.text)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DiffToolTheme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(DiffToolTheme.border)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("KEY TRACE (debug)")
                            .font(.caption)
                            .foregroundStyle(DiffToolTheme.muted)
                        TextField("Entry key to trace", text: $viewModel.debugTraceKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Print comparison trace") {
                            Task { await viewModel.runKeyTrace() }
                        }
                        .buttonStyle(DiffToolSecondaryButtonStyle())
                        .disabled(viewModel.isTracingKey || viewModel.isScanning)
                        if viewModel.isTracingKey {
                            ProgressView().controlSize(.small)
                        }
                        if !viewModel.debugTraceOutput.isEmpty {
                            ScrollView {
                                Text(viewModel.debugTraceOutput)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(DiffToolTheme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 280)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
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

                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(DiffToolTheme.error)
                }

                if let result = viewModel.scanResult {
                    summarySection(result)

                    if !result.languages.isEmpty {
                        HStack(spacing: 12) {
                            Button("Select All") { viewModel.selectAllLanguages() }
                                .buttonStyle(DiffToolSecondaryButtonStyle())
                            Button("Deselect All") { viewModel.deselectAllLanguages() }
                                .buttonStyle(DiffToolSecondaryButtonStyle())
                        }
                        .disabled(viewModel.isScanning)

                        languagesSection(result)
                    } else {
                        Text("No non-English locales with .strings / String Catalog entries were found, or all locales match the English key set.")
                            .font(.subheadline)
                            .foregroundStyle(DiffToolTheme.muted)
                    }
                }
            }
            .padding(20)
        }
        .background(DiffToolTheme.background)
        .navigationTitle("Localization vs English")
        .toolbarBackground(DiffToolTheme.background, for: .automatic)
    }

    @ViewBuilder
    private func summarySection(_ result: LocalizationCompareScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUMMARY")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)
            HStack(spacing: 18) {
                Label("English reference: \(result.englishReferenceDescription)", systemImage: "character.book.closed")
                Label("English keys: \(result.englishKeyCount)", systemImage: "number")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DiffToolTheme.text)

            if result.usedStringsFilesAsReference {
                Text("Compare mode: `.lproj` `.strings` only — String Catalog is not used for reference or locale rows.")
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
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
    private func languagesSection(_ result: LocalizationCompareScanResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOCALES")
                .font(.caption)
                .foregroundStyle(DiffToolTheme.muted)

            ForEach(result.languages) { row in
                let included = viewModel.includedLanguageCodes.contains(row.languageCode)
                DisclosureGroup {
                    if included {
                        if row.missingEntries.isEmpty {
                            Text("No missing keys.")
                                .font(.subheadline)
                                .foregroundStyle(DiffToolTheme.ok)
                                .padding(.vertical, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(row.missingEntries) { entry in
                                    missingKeyRow(entry)
                                }
                            }
                            .padding(.top, 6)
                        }
                    } else {
                        Text("Unchecked — details hidden.")
                            .font(.subheadline)
                            .foregroundStyle(DiffToolTheme.muted)
                            .padding(.vertical, 4)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { viewModel.includedLanguageCodes.contains(row.languageCode) },
                                set: { viewModel.setIncluded(row.languageCode, isOn: $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.checkbox)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.languageCode)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DiffToolTheme.text)
                            Text("\(row.missingEntries.count) missing key(s)")
                                .font(.caption)
                                .foregroundStyle(DiffToolTheme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .tint(DiffToolTheme.accent)
            }
        }
    }

    @ViewBuilder
    private func missingKeyRow(_ entry: MissingLocalizationEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.key)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(DiffToolTheme.onlyB)
                .textSelection(.enabled)
            if !entry.englishValue.isEmpty {
                Text(entry.englishValue)
                    .font(.caption)
                    .foregroundStyle(DiffToolTheme.muted)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DiffToolTheme.lineDim))
    }
}

#Preview {
    NavigationStack {
        LocalizationCompareToolView()
    }
    .frame(minWidth: 700, minHeight: 500)
}
