import Foundation
import os

enum NexLog {
    private static let subsystem = "com.nexia.nexoperator"

    static let general = os.Logger(subsystem: subsystem, category: "general")
    static let terminal = os.Logger(subsystem: subsystem, category: "terminal")
    static let ai = os.Logger(subsystem: subsystem, category: "ai")
    static let safety = os.Logger(subsystem: subsystem, category: "safety")
    static let config = os.Logger(subsystem: subsystem, category: "config")
    static let git = os.Logger(subsystem: subsystem, category: "git")
}
