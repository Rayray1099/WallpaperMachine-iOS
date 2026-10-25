import SwiftUI
import UIKit
import WebKit

/// Steam's own sign-in page in a private web view. The app never sees the password or the
/// Steam Guard code; when Steam sets its session cookies the model hands exactly those two
/// cookie values to the caller, and the web view's non-persistent data store goes away with
/// the sheet.
@MainActor
final class WorkshopSteamSignInModel: NSObject, ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var session: SteamWebSession?

    let webView: WKWebView
    private var finished = false

    private static let signInURL = URL(string: "https://steamcommunity.com/login/home/?goto=")!
    private static let sessionDomains: Set<String> = [
        "steamcommunity.com", ".steamcommunity.com",
    ]
    private static let companionDomains: Set<String> = [
        "login.steampowered.com", ".login.steampowered.com", ".steampowered.com",
    ]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: Self.signInURL))
    }

    deinit {
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView.stopLoading()
    }

    /// The sheet went away: stop the page and release its private data store.
    func tearDown() {
        finished = true
        webView.stopLoading()
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
    }

    /// A cookie snapshot from Steam's private store. The app looks only for the two cookies
    /// the macOS app uses; anything else typed or stored on the page stays there.
    func checkCookies() {
        guard !finished, session == nil else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in
                guard let self, !self.finished, self.session == nil else { return }
                guard let sessionCookie = cookies.first(where: {
                    $0.name == "steamLoginSecure" && Self.sessionDomains.contains($0.domain)
                        && SteamWebSession(cookie: $0.value) != nil
                }) else { return }
                let companion = cookies.first {
                    $0.name == "steamRefresh_steam" && Self.companionDomains.contains($0.domain)
                }
                guard let session = SteamWebSession(
                    cookie: sessionCookie.value, refresh: companion?.value)
                else { return }
                self.finished = true
                self.session = session
                self.webView.stopLoading()
            }
        }
    }

    private func showFailure(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        errorMessage = error.localizedDescription
        isLoading = false
    }
}

extension WorkshopSteamSignInModel: WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        return scheme == "https" || scheme == "about" ? .allow : .cancel
    }

    // A page that opens a window of its own continues in this one instead.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.request.url?.scheme?.lowercased() == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        checkCookies()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showFailure(error)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        showFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = WS(
            "Steam’s sign-in page stopped unexpectedly. Close and try again.",
            "Steam 登入頁面意外停止。請關閉後再試。")
        isLoading = false
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.checkCookies()
        }
    }
}

/// The sheet that hosts `WorkshopSteamSignInModel`. The explanatory text is deliberately
/// explicit that the password is typed into Steam's page, not into this app.
struct WorkshopSteamSignInView: View {
    @StateObject private var model = WorkshopSteamSignInModel()
    let onSession: (SteamWebSession) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(WS(
                        "Sign in on Steam’s own page. This app never sees your password or Steam Guard code; it keeps only the session cookies in the Keychain, and uses them to read your Workshop subscriptions.",
                        "請在 Steam 自己的頁面登入。本 App 不會看到你的密碼或 Steam Guard 驗證碼，只會將工作階段 Cookie 存放在鑰匙圈，用來讀取你的工作坊訂閱。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                ZStack {
                    WorkshopSteamWebView(webView: model.webView)
                    if model.isLoading {
                        ProgressView()
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.red.opacity(0.85))
                    }
                }
            }
            .navigationTitle(WS("Sign in to Steam", "登入 Steam"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WS("Cancel", "取消")) {
                        dismiss()
                    }
                }
            }
            .onChange(of: model.session) { _, new in
                guard let new else { return }
                onSession(new)
                dismiss()
            }
            .onDisappear {
                model.tearDown()
            }
            .accessibilityIdentifier("wm.workshop.signin")
        }
    }
}

private struct WorkshopSteamWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
