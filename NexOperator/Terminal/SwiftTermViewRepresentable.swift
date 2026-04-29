import SwiftUI
import SwiftTerm
import AppKit

struct SwiftTermViewRepresentable: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminalView
        view.configureNativeColors()

        DispatchQueue.main.async {
            session.startIfNeeded()
        }

        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if !session.isRunning {
            DispatchQueue.main.async {
                session.startIfNeeded()
            }
        }
    }
}
