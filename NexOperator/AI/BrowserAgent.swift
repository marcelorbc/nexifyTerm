import Foundation
import WebKit

@MainActor
class BrowserAgent {
    static let shared = BrowserAgent()

    private(set) weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func detach() {
        self.webView = nil
    }

    var isAttached: Bool { webView != nil }

    func getPageInfo() async -> String {
        guard let webView else { return "{\"error\": \"Browser not attached\"}" }

        let js = """
        (function() {
            var forms = document.querySelectorAll('form');
            var formInfo = [];
            forms.forEach(function(f, fi) {
                var fields = [];
                f.querySelectorAll('input, select, textarea').forEach(function(el) {
                    fields.push({
                        tag: el.tagName.toLowerCase(),
                        type: el.type || '',
                        name: el.name || '',
                        id: el.id || '',
                        placeholder: el.placeholder || '',
                        value: el.value || ''
                    });
                });
                formInfo.push({index: fi, action: f.action, method: f.method, fields: fields});
            });

            var links = [];
            document.querySelectorAll('a[href]').forEach(function(a, i) {
                if (i < 50) links.push({text: a.innerText.trim().substring(0,80), href: a.href});
            });

            var buttons = [];
            document.querySelectorAll('button, input[type="submit"], input[type="button"]').forEach(function(b) {
                buttons.push({text: (b.innerText || b.value || '').trim().substring(0,80), type: b.type || 'button', id: b.id || ''});
            });

            var images = [];
            document.querySelectorAll('img[src]').forEach(function(img, i) {
                if (i < 30) images.push({src: img.src, alt: img.alt || '', width: img.naturalWidth, height: img.naturalHeight});
            });

            var inputs = [];
            document.querySelectorAll('input:not([type="hidden"]), select, textarea').forEach(function(el) {
                inputs.push({
                    tag: el.tagName.toLowerCase(),
                    type: el.type || '',
                    name: el.name || '',
                    id: el.id || '',
                    placeholder: el.placeholder || '',
                    value: el.value || '',
                    cssSelector: el.id ? '#' + el.id : (el.name ? '[name="' + el.name + '"]' : el.tagName.toLowerCase())
                });
            });

            return JSON.stringify({
                url: window.location.href,
                title: document.title,
                forms: formInfo,
                links: links,
                buttons: buttons,
                images: images,
                inputs: inputs,
                bodyText: document.body.innerText.substring(0, 3000)
            });
        })()
        """

        do {
            let result = try await webView.evaluateJavaScript(js)
            return (result as? String) ?? "{\"error\": \"Invalid JS result\"}"
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }

    func executeAction(_ action: BrowserAction) async -> BrowserActionResult {
        guard let webView else {
            return BrowserActionResult(action: action, output: "Browser não está aberto", success: false)
        }

        do {
            switch action.action {
            case "getPageInfo":
                let info = await getPageInfo()
                return BrowserActionResult(action: action, output: info, success: true)

            case "click":
                guard let selector = action.selector else {
                    return BrowserActionResult(action: action, output: "Selector não fornecido", success: false)
                }
                let js = """
                (function() {
                    var el = document.querySelector('\(escapeJS(selector))');
                    if (!el) return 'Elemento não encontrado: \(escapeJS(selector))';
                    el.click();
                    return 'Clicado: ' + (el.innerText || el.value || el.tagName).substring(0, 100);
                })()
                """
                let result = try await webView.evaluateJavaScript(js)
                return BrowserActionResult(action: action, output: (result as? String) ?? "OK", success: true)

            case "fill":
                guard let selector = action.selector, let value = action.value else {
                    return BrowserActionResult(action: action, output: "Selector ou value não fornecido", success: false)
                }
                let js = """
                (function() {
                    var el = document.querySelector('\(escapeJS(selector))');
                    if (!el) return 'Elemento não encontrado: \(escapeJS(selector))';
                    el.value = '\(escapeJS(value))';
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'Preenchido: ' + el.name + ' = ' + el.value;
                })()
                """
                let result = try await webView.evaluateJavaScript(js)
                return BrowserActionResult(action: action, output: (result as? String) ?? "OK", success: true)

            case "extract":
                guard let selector = action.selector else {
                    return BrowserActionResult(action: action, output: "Selector não fornecido", success: false)
                }
                let js = """
                (function() {
                    var els = document.querySelectorAll('\(escapeJS(selector))');
                    if (els.length === 0) return 'Nenhum elemento encontrado: \(escapeJS(selector))';
                    var results = [];
                    els.forEach(function(el, i) {
                        if (i < 20) results.push(el.innerText || el.value || el.src || '');
                    });
                    return JSON.stringify(results);
                })()
                """
                let result = try await webView.evaluateJavaScript(js)
                return BrowserActionResult(action: action, output: (result as? String) ?? "[]", success: true)

            case "downloadImages":
                let js = """
                (function() {
                    var imgs = document.querySelectorAll('img[src]');
                    var urls = [];
                    imgs.forEach(function(img) {
                        var src = img.src;
                        if (src && !src.startsWith('data:')) urls.push(src);
                    });
                    return JSON.stringify(urls);
                })()
                """
                let result = try await webView.evaluateJavaScript(js)
                let urlsJson = (result as? String) ?? "[]"

                guard let urlsData = urlsJson.data(using: .utf8),
                      let urls = try? JSONDecoder().decode([String].self, from: urlsData) else {
                    return BrowserActionResult(action: action, output: "Nenhuma imagem encontrada", success: false)
                }

                let downloadDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/NexOperator-Images")
                try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

                var downloaded = 0
                for (i, urlStr) in urls.prefix(20).enumerated() {
                    guard let url = URL(string: urlStr) else { continue }
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                        let filename = "img_\(i + 1).\(ext)"
                        let filePath = downloadDir.appendingPathComponent(filename)
                        try data.write(to: filePath)
                        downloaded += 1
                    } catch {
                        NexLog.ai.warning("Failed to download image: \(urlStr)")
                    }
                }

                let summary = "\(downloaded) imagens baixadas em ~/Downloads/NexOperator-Images/ (de \(urls.count) encontradas)"
                return BrowserActionResult(action: action, output: summary, success: downloaded > 0)

            case "scroll":
                let direction = action.value ?? "down"
                let js: String
                switch direction {
                case "top":
                    js = "window.scrollTo(0, 0); 'Scroll para o topo'"
                case "bottom":
                    js = "window.scrollTo(0, document.body.scrollHeight); 'Scroll para o final'"
                case "up":
                    js = "window.scrollBy(0, -500); 'Scroll para cima'"
                default:
                    js = "window.scrollBy(0, 500); 'Scroll para baixo'"
                }
                let result = try await webView.evaluateJavaScript(js)
                return BrowserActionResult(action: action, output: (result as? String) ?? "OK", success: true)

            case "navigate":
                guard let urlStr = action.value, let url = URL(string: urlStr) else {
                    return BrowserActionResult(action: action, output: "URL inválida", success: false)
                }
                webView.load(URLRequest(url: url))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return BrowserActionResult(action: action, output: "Navegado para: \(urlStr)", success: true)

            case "runJS":
                guard let code = action.value else {
                    return BrowserActionResult(action: action, output: "Código JS não fornecido", success: false)
                }
                let result = try await webView.evaluateJavaScript(code)
                let output = result.map { "\($0)" } ?? "undefined"
                return BrowserActionResult(action: action, output: String(output.prefix(5000)), success: true)

            case "screenshot":
                let config = WKSnapshotConfiguration()
                let image = try await webView.takeSnapshot(configuration: config)

                let downloadDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/NexOperator-Images")
                try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

                let timestamp = Int(Date().timeIntervalSince1970)
                let filePath = downloadDir.appendingPathComponent("screenshot_\(timestamp).png")

                guard let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    return BrowserActionResult(action: action, output: "Falha ao gerar PNG", success: false)
                }
                try pngData.write(to: filePath)

                return BrowserActionResult(action: action, output: "Screenshot salvo: \(filePath.path)", success: true)

            default:
                return BrowserActionResult(action: action, output: "Ação desconhecida: \(action.action)", success: false)
            }
        } catch {
            return BrowserActionResult(action: action, output: "Erro: \(error.localizedDescription)", success: false)
        }
    }

    private func escapeJS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "'", with: "\\'")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
    }
}
