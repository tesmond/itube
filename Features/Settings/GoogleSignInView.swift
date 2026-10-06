import ITubeCore
import SwiftUI
import WebKit

/// Isolated sign-in flow (ADR §51, §77): a non-persistent web view, restricted to Google/YouTube hosts. On success only the
/// allow-listed cookies are handed to the Keychain-backed `AuthenticationProvider`; the web view and its data are discarded.
struct GoogleSignInView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInWebView { cookies in
                Task {
                    if (try? await account.signIn(cookies: cookies)) != nil { dismiss() }
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    var onCookies: @MainActor ([StoredCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()                 // nothing persists in WebKit
        config.applicationNameForUserAgent = "Version/18.1 Mobile/15E148 Safari/604.1"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookies: @MainActor ([StoredCookie]) -> Void
        private var delivered = false
        private static let allowedHostSuffixes = ["google.com", "youtube.com", "gstatic.com", "googleusercontent.com", "ggpht.com"]

        init(onCookies: @escaping @MainActor ([StoredCookie]) -> Void) { self.onCookies = onCookies }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            if url?.scheme == "about" { return .allow }
            guard let url, url.scheme == "https", let host = url.host()?.lowercased(),
                  Self.allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, let host = webView.url?.host()?.lowercased(), host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                let stored = cookies.map {
                    StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate, isSecure: $0.isSecure)
                }
                guard stored.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else { return }
                MainActor.assumeIsolated {
                    guard let self, !self.delivered else { return }
                    self.delivered = true
                    self.onCookies(stored)
                }
            }
        }
    }
}
