import SwiftUI
import WebKit

struct WebPreviewPanel: View {
    let html: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text("Visualização")
                    .font(.caption.bold())
                    .foregroundColor(NexTheme.textPrimary)

                Spacer()

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(html, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Copiar HTML")

                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBackground()

            WebViewRepresentable(html: wrappedHTML)
                .frame(maxHeight: 300)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
    }

    private var wrappedHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
                background: rgb(15, 15, 20);
                color: rgb(230, 230, 240);
                padding: 16px;
                font-size: 13px;
                line-height: 1.5;
            }
            h1, h2, h3 { color: rgb(143, 92, 255); margin-bottom: 8px; }
            h1 { font-size: 18px; }
            h2 { font-size: 15px; }
            h3 { font-size: 13px; }
            table {
                width: 100%;
                border-collapse: collapse;
                margin: 8px 0;
            }
            th {
                background: rgba(143, 92, 255, 0.15);
                color: rgb(143, 92, 255);
                text-align: left;
                padding: 6px 8px;
                font-size: 11px;
                font-weight: 600;
            }
            td {
                padding: 5px 8px;
                border-bottom: 1px solid rgba(255,255,255,0.05);
                font-size: 12px;
                font-family: 'SF Mono', monospace;
            }
            tr:nth-child(even) { background: rgba(255,255,255,0.02); }
            code {
                background: rgba(255,255,255,0.06);
                padding: 2px 5px;
                border-radius: 3px;
                font-size: 12px;
            }
            pre {
                background: rgba(255,255,255,0.04);
                padding: 10px;
                border-radius: 6px;
                overflow-x: auto;
                font-size: 12px;
            }
            a { color: rgb(143, 92, 255); }
            .metric {
                display: inline-block;
                background: rgba(255,255,255,0.04);
                border: 1px solid rgba(255,255,255,0.06);
                border-radius: 8px;
                padding: 10px 14px;
                margin: 4px;
                min-width: 120px;
            }
            .metric-value {
                font-size: 22px;
                font-weight: 700;
                color: rgb(143, 92, 255);
            }
            .metric-label {
                font-size: 10px;
                color: rgba(230,230,240,0.5);
                text-transform: uppercase;
            }
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
