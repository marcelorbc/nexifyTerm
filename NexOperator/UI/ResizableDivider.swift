import SwiftUI

struct ResizableDivider: View {
    @Binding var topRatio: CGFloat
    let minRatio: CGFloat = 0.15
    let maxRatio: CGFloat = 0.85

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? NexTheme.accent.opacity(0.5) : NexTheme.border)
            .frame(height: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(isDragging ? NexTheme.accent : NexTheme.textSecondary.opacity(0.3))
                    .frame(width: 36, height: 3)
            )
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("splitContainer"))
                    .onChanged { value in
                        isDragging = true
                    }
            )
            .cursorOnHover(.resizeUpDown)
    }
}

// MARK: - Reusable Cursor Modifier

extension View {
    func cursorOnHover(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
