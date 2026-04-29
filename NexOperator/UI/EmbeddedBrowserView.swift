import SwiftUI
import WebKit

struct EmbeddedBrowserView: View {
    let initialURL: URL
    let onDismiss: () -> Void

    @State private var currentURL: String
    @State private var pageTitle: String = ""
    @State private var isLoading = true
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var urlInput: String

    init(initialURL: URL, onDismiss: @escaping () -> Void) {
        self.initialURL = initialURL
        self.onDismiss = onDismiss
        _currentURL = State(initialValue: initialURL.absoluteString)
        _urlInput = State(initialValue: initialURL.absoluteString)
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Rectangle().fill(NexTheme.border).frame(height: 0.5)
            BrowserWebView(
                url: initialURL,
                currentURL: $currentURL,
                pageTitle: $pageTitle,
                isLoading: $isLoading,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward
            )
        }
        .background(NexTheme.bg)
        .onChange(of: currentURL) { _, newVal in
            urlInput = newVal
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 6) {
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Voltar ao terminal")

            Button {
                NotificationCenter.default.post(name: .browserGoBack, object: nil)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(canGoBack ? NexTheme.textPrimary : NexTheme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)

            Button {
                NotificationCenter.default.post(name: .browserGoForward, object: nil)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(canGoForward ? NexTheme.textPrimary : NexTheme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)

            Button {
                NotificationCenter.default.post(name: .browserReload, object: nil)
            } label: {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }

                Image(systemName: currentURL.hasPrefix("https") ? "lock.fill" : "globe")
                    .font(.system(size: 9))
                    .foregroundColor(currentURL.hasPrefix("https") ? .green : NexTheme.textSecondary)

                TextField("URL", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                    .onSubmit {
                        if let url = URL(string: urlInput) {
                            NotificationCenter.default.post(name: .browserNavigate, object: url)
                        }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NexTheme.bg)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NexTheme.border, lineWidth: 0.5)
            )

            Button {
                if let url = URL(string: currentURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Abrir no Safari")

            Text(pageTitle)
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassBackground()
    }
}

extension Notification.Name {
    static let browserGoBack = Notification.Name("browserGoBack")
    static let browserGoForward = Notification.Name("browserGoForward")
    static let browserReload = Notification.Name("browserReload")
    static let browserNavigate = Notification.Name("browserNavigate")
}

struct BrowserWebView: NSViewRepresentable {
    let url: URL
    @Binding var currentURL: String
    @Binding var pageTitle: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        context.coordinator.webView = webView
        context.coordinator.setupObservers()

        Task { @MainActor in
            BrowserAgent.shared.attach(webView)
        }

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BrowserWebView
        weak var webView: WKWebView?
        private var observers: [Any] = []
        private var kvoTokens: [NSKeyValueObservation] = []

        init(_ parent: BrowserWebView) {
            self.parent = parent
        }

        func setupObservers() {
            guard let wv = webView else { return }

            observers.append(
                NotificationCenter.default.addObserver(forName: .browserGoBack, object: nil, queue: .main) { [weak self] _ in
                    self?.webView?.goBack()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .browserGoForward, object: nil, queue: .main) { [weak self] _ in
                    self?.webView?.goForward()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .browserReload, object: nil, queue: .main) { [weak self] _ in
                    self?.webView?.reload()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .browserNavigate, object: nil, queue: .main) { [weak self] notif in
                    if let url = notif.object as? URL {
                        self?.webView?.load(URLRequest(url: url))
                    }
                }
            )

            kvoTokens.append(
                wv.observe(\.url) { [weak self] webView, _ in
                    DispatchQueue.main.async {
                        self?.parent.currentURL = webView.url?.absoluteString ?? ""
                    }
                }
            )
            kvoTokens.append(
                wv.observe(\.title) { [weak self] webView, _ in
                    DispatchQueue.main.async {
                        self?.parent.pageTitle = webView.title ?? ""
                    }
                }
            )
            kvoTokens.append(
                wv.observe(\.isLoading) { [weak self] webView, _ in
                    DispatchQueue.main.async {
                        self?.parent.isLoading = webView.isLoading
                    }
                }
            )
            kvoTokens.append(
                wv.observe(\.canGoBack) { [weak self] webView, _ in
                    DispatchQueue.main.async {
                        self?.parent.canGoBack = webView.canGoBack
                    }
                }
            )
            kvoTokens.append(
                wv.observe(\.canGoForward) { [weak self] webView, _ in
                    DispatchQueue.main.async {
                        self?.parent.canGoForward = webView.canGoForward
                    }
                }
            )
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
            Task { @MainActor in
                BrowserAgent.shared.detach()
            }
        }
    }
}
