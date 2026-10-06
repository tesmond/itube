import Foundation

public enum RequestDecision: Sendable, Equatable { case allow, deny }

public protocol RequestPolicy: Sendable {
    func evaluate(_ request: URLRequest) -> RequestDecision
}

public struct AllowAllPolicy: RequestPolicy {
    public init() {}
    public func evaluate(_ request: URLRequest) -> RequestDecision { .allow }
}

/// Denies requests whose host equals or is a subdomain of a listed domain. Data-only rules (§70).
public struct DomainDenylistPolicy: RequestPolicy {
    public static let defaultDomains: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "app-measurement.com", "scorecardresearch.com", "facebook.net", "adjust.com", "appsflyer.com",
    ]

    private let domains: [String]

    public init(domains: [String] = DomainDenylistPolicy.defaultDomains) {
        self.domains = domains.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    public func evaluate(_ request: URLRequest) -> RequestDecision {
        guard let host = request.url?.host()?.lowercased() else { return .allow }
        for d in domains where host == d || host.hasSuffix("." + d) { return .deny }
        return .allow
    }
}

public struct CompositePolicy: RequestPolicy {
    private let policies: [any RequestPolicy]
    public init(_ policies: [any RequestPolicy]) { self.policies = policies }
    public func evaluate(_ request: URLRequest) -> RequestDecision {
        policies.contains { $0.evaluate(request) == .deny } ? .deny : .allow
    }
}
