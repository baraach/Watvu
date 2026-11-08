import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL
    let onNavigate: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigate: (URL) -> Void

        init(onNavigate: @escaping (URL) -> Void) {
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                onNavigate(url)
            }
            decisionHandler(.allow)
        }
    }
}
