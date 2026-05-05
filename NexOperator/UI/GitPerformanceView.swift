import SwiftUI

/// Diagnostic modal that benchmarks the user's local Git operations and
/// shows actionable suggestions (e.g. `git gc`, large repo warnings).
struct GitPerformanceView: View {
    @ObservedObject var viewModel: GitViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 480)
        .frame(idealWidth: 720, idealHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Auto-run on first open if we haven't measured yet.
            if viewModel.perfReport == nil, !viewModel.isRunningPerf {
                await viewModel.runPerformanceAnalysis()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnóstico de Performance Git")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
                Text(viewModel.repoPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if let r = viewModel.perfReport {
                ratingBadge(r.overallRating, big: true)
            }

            Button {
                Task { await viewModel.runPerformanceAnalysis() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("Re-medir")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor)
                .foregroundColor(.black)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRunningPerf)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if viewModel.isRunningPerf && viewModel.perfReport == nil {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Medindo operações Git…")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = viewModel.perfReport {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    samplesSection(report)
                    suggestionsSection(report)
                    footer(report)
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Text("Nenhuma medição ainda.")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)
                Button("Rodar diagnóstico") {
                    Task { await viewModel.runPerformanceAnalysis() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sections

    private func samplesSection(_ report: GitPerfReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Medições", systemImage: "stopwatch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
                if viewModel.isRunningPerf {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Re-medindo…")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                }
            }
            VStack(spacing: 1) {
                ForEach(report.samples) { sample in
                    sampleRow(sample, max: maxDuration(report))
                }
            }
            .background(NexTheme.surface.opacity(0.5))
            .cornerRadius(8)
        }
    }

    private func sampleRow(_ sample: GitPerfSample, max: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sample.rating.icon)
                .font(.system(size: 11))
                .foregroundColor(sample.rating.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(sample.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
                Text(sample.detail)
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Bar (only for timed samples).
            if sample.durationSeconds > 0 {
                HStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NexTheme.surface)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(sample.rating.color.opacity(0.6))
                                .frame(width: max > 0 ? geo.size.width * CGFloat(sample.durationSeconds / max) : 0)
                        }
                    }
                    .frame(width: 110, height: 6)
                }
            }

            Text(sample.rating.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(sample.rating.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sample.rating.color.opacity(0.12))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
    }

    private func suggestionsSection(_ report: GitPerfReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sugestões", systemImage: "lightbulb")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.suggestions, id: \.self) { s in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor.opacity(0.7))
                            .padding(.top, 1)
                        Text(s)
                            .font(.system(size: 11))
                            .foregroundColor(NexTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(NexTheme.surface.opacity(0.4))
                    .cornerRadius(5)
                }
            }
        }
    }

    private func footer(_ report: GitPerfReport) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return HStack {
            Text("Medido em \(formatter.string(from: report.measuredAt))")
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func maxDuration(_ report: GitPerfReport) -> Double {
        report.samples.map(\.durationSeconds).max() ?? 0
    }

    private func ratingBadge(_ rating: GitPerfSample.Rating, big: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: rating.icon)
                .font(.system(size: big ? 12 : 10, weight: .semibold))
            Text(rating.rawValue)
                .font(.system(size: big ? 12 : 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, big ? 5 : 3)
        .background(rating.color.opacity(0.15))
        .foregroundColor(rating.color)
        .cornerRadius(5)
    }
}
