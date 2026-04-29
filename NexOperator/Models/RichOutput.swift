import Foundation

struct RichOutput: Codable {
    var metrics: [RichMetric]?
    var table: RichTable?
    var chart: RichChart?
    var html: String?
    var openUrl: String?
}

struct RichMetric: Codable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let icon: String?
    let color: String?
    let subtitle: String?
}

struct RichTable: Codable {
    let title: String?
    let headers: [String]
    let rows: [[String]]
}

struct RichChart: Codable {
    let title: String?
    let type: String // "bar", "pie", "progress"
    let items: [RichChartItem]
}

struct RichChartItem: Codable, Identifiable {
    var id: String { label }
    let label: String
    let value: Double
    let color: String?
}
