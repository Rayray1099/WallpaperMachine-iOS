// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import WebKit

@MainActor
struct PixivSignInView: View {
    @Environment(\.dismiss) private var dismiss
    let onSession: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("pixiv.signIn.instructions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                PixivLoginWebView(onSession: onSession)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(Text("pixiv.signIn.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("pixiv.done", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct PixivLoginWebView: UIViewRepresentable {
    let onSession: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSession: onSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: Self.signInURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup(webView)
    }

    private static let signInURL = URL(
        string: "https://accounts.pixiv.net/login?return_to=https%3A%2F%2Fwww.pixiv.net%2F&source=pc&view_type=page")!

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        private let onSession: (String) -> Void
        private weak var webView: WKWebView?
        private var completed = false

        init(onSession: @escaping (String) -> Void) {
            self.onSession = onSession
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased()
            decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url,
                  url.scheme?.lowercased() == "https" else { return nil }
            webView.load(navigationAction.request)
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            findSession(in: webView)
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor [weak self] in
                guard let self, let webView = self.webView else { return }
                self.findSession(in: webView)
            }
        }

        private func findSession(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let cookie = cookies.first(where: {
                    $0.name == "PHPSESSID"
                        && ($0.domain == ".pixiv.net" || $0.domain == "pixiv.net")
                        && $0.isSecure
                        && PixivService.isSessionValue($0.value)
                }) else { return }
                let sessionValue = cookie.value
                Task { @MainActor [weak self] in
                    guard let self, !self.completed else { return }
                    self.completed = true
                    self.onSession(sessionValue)
                }
            }
        }

        func cleanup(_ webView: WKWebView) {
            completed = true
            let dataStore = webView.configuration.websiteDataStore
            dataStore.httpCookieStore.remove(self)
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            self.webView = nil

            dataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies { dataStore.httpCookieStore.delete(cookie) }
            }
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast,
                completionHandler: {})
        }
    }
}
