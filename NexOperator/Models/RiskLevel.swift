import Foundation
import SwiftUI

enum RiskLevel: String, Codable, Comparable {
    case readOnly
    case low
    case medium
    case high
    case blocked

    var displayName: String {
        switch self {
        case .readOnly: return "Read Only"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .blocked: return "Blocked"
        }
    }

    var color: Color {
        switch self {
        case .readOnly: return .green
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .orange
        case .blocked: return .red
        }
    }

    var icon: String {
        switch self {
        case .readOnly: return "eye"
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.triangle"
        case .high: return "exclamationmark.octagon"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .readOnly: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .blocked: return 4
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
