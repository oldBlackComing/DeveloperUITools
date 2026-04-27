//
//  LocalizationMissingEntryID.swift
//  WYTools
//

import Foundation

/// Identifies one missing key row for a specific locale (used for per-row checkboxes).
struct LocalizationMissingEntryID: Hashable, Sendable {
    let languageCode: String
    let key: String
}
