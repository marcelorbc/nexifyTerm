import AppKit
import SwiftUI

final class DropDownWindow {
    static let shared = DropDownWindow()

    private var panel: NSPanel?
    private var isVisible = false
    private let animationDuration: TimeInterval = 0.25

    weak var appState: AppState?

    var isShowing: Bool { isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }

        let panel = getOrCreatePanel()
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame

        let width = screenFrame.width * 0.85
        let height = screenFrame.height * 0.45
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let startY = screenFrame.origin.y + screenFrame.height

        panel.setFrame(NSRect(x: x, y: startY, width: width, height: height), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()

        let targetY = screenFrame.origin.y + screenFrame.height - height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: x, y: targetY, width: width, height: height),
                display: true
            )
        })

        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    func hide() {
        guard isVisible, let panel else { return }

        let frame = panel.frame
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let targetY = screen.visibleFrame.origin.y + screen.visibleFrame.height

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(
                NSRect(x: frame.origin.x, y: targetY, width: frame.width, height: frame.height),
                display: true
            )
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isVisible = false
        })
    }

    private func getOrCreatePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        p.isFloatingPanel = true
        p.level = .floating
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow

        if let state = appState {
            let rootView = TerminalContainerView()
                .environmentObject(state)
            p.contentView = NSHostingView(rootView: rootView)
        }

        p.delegate = WindowDelegate.shared
        panel = p
        return p
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowDelegate()

    func windowWillClose(_ notification: Notification) {
        DropDownWindow.shared.hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        if ConfigStore.shared.hotKeyHideOnFocusLost {
            DropDownWindow.shared.hide()
        }
    }
}
