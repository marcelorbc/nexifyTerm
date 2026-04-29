import SwiftUI

struct AgentRunningBadge: View {
    let startTime: Date?
    let onCancel: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let slowThreshold: TimeInterval = 30

    private var isSlow: Bool { elapsed >= slowThreshold }

    var body: some View {
        HStack(spacing: 4) {
            if isSlow {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                        Text("Derrubar")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.2))
                    .foregroundColor(.red)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Text(formattedElapsed)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            } else {
                ProgressView()
                    .controlSize(.mini)
                Text("Executando...")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }
        }
        .onReceive(timer) { _ in
            if let start = startTime {
                elapsed = Date().timeIntervalSince(start)
            }
        }
        .onAppear {
            if let start = startTime {
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private var formattedElapsed: String {
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return mins > 0 ? String(format: "%dm %02ds", mins, secs) : String(format: "%ds", secs)
    }
}
