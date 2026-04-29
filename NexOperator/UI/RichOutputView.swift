import SwiftUI
import Charts

struct RichOutputView: View {
    let output: RichOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let metrics = output.metrics, !metrics.isEmpty {
                MetricCardsView(metrics: metrics)
            }

            if let chart = output.chart {
                RichChartView(chart: chart)
            }

            if let table = output.table {
                RichTableView(table: table)
            }
        }
    }
}

// MARK: - Metric Cards

struct MetricCardsView: View {
    let metrics: [RichMetric]

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(metrics) { metric in
                MetricCard(metric: metric)
            }
        }
    }
}

struct MetricCard: View {
    let metric: RichMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let icon = metric.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
                Text(metric.label)
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }

            Text(metric.value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(colorFor(metric.color))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let sub = metric.subtitle {
                Text(sub)
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .glassCard(cornerRadius: 8)
    }

    private func colorFor(_ name: String?) -> Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "blue": return .blue
        case "purple": return NexTheme.accent
        default: return NexTheme.textPrimary
        }
    }
}

// MARK: - Chart

struct RichChartView: View {
    let chart: RichChart

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = chart.title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
            }

            switch chart.type {
            case "bar":
                barChart
            case "progress":
                progressBars
            default:
                barChart
            }
        }
        .padding(8)
        .glassCard(cornerRadius: 8)
    }

    private var barChart: some View {
        Chart(chart.items) { item in
            BarMark(
                x: .value("Label", item.label),
                y: .value("Value", item.value)
            )
            .foregroundStyle(Color.accentColor)
            .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .foregroundStyle(NexTheme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .foregroundStyle(NexTheme.textSecondary)
                AxisGridLine()
                    .foregroundStyle(NexTheme.border)
            }
        }
        .frame(height: 120)
    }

    private var progressBars: some View {
        VStack(spacing: 6) {
            let maxVal = chart.items.map(\.value).max() ?? 1

            ForEach(chart.items) { item in
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 80, alignment: .trailing)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(NexTheme.surfaceHover)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(item.value / maxVal))
                        }
                    }
                    .frame(height: 10)

                    Text(String(format: "%.1f", item.value))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(NexTheme.textPrimary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Table

struct RichTableView: View {
    let table: RichTable

    private var columnWidths: [CGFloat] {
        let displayRows = Array(table.rows.prefix(20))
        let minWidth: CGFloat = 60
        let maxWidth: CGFloat = 300
        let charWidth: CGFloat = 7.0

        return table.headers.enumerated().map { idx, header in
            var maxLen = header.count
            for row in displayRows {
                if idx < row.count {
                    maxLen = max(maxLen, row[idx].count)
                }
            }
            let computed = CGFloat(maxLen) * charWidth + 20
            return min(max(computed, minWidth), maxWidth)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = table.title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(table.headers.enumerated()), id: \.offset) { idx, header in
                            Text(header)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(NexTheme.accent)
                                .lineLimit(1)
                                .frame(width: columnWidths[safe: idx] ?? 100, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                    }
                    .background(NexTheme.accentDim)

                    ForEach(Array(table.rows.prefix(20).enumerated()), id: \.offset) { idx, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                                Text(cell)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(NexTheme.textPrimary)
                                    .lineLimit(2)
                                    .frame(width: columnWidths[safe: colIdx] ?? 100, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                            }
                        }
                        .background(idx % 2 == 0 ? Color.clear : NexTheme.surface)
                    }
                }
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NexTheme.border, lineWidth: 0.5)
            )
        }
        .padding(8)
        .glassCard(cornerRadius: 8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
