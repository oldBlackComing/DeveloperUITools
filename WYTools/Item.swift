//
//  Item.swift
//  WYTools
//
//  Created by Developer_wy on 2026/4/16.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
