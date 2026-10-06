import Foundation

/// Everything that changes when YouTube changes its internal clients lives here, in one replaceable value.
/// NOTE (ADR §25): InnerTube is an undocumented API. Using it is a product/legal decision owned by the project.
public struct InnerTubeConfig: Sendable, Equatable {
    public struct Client: Sendable, Equatable {
        public var name: String
        public var nameID: Int
        public var version: String
        public var userAgent: String
        public var deviceMake: String?
        public var deviceModel: String?
        public var osName: String?
        public var osVersion: String?
    }

    public var baseURL: URL
    public var origin: URL
    public var hl: String
    public var gl: String
    public var web: Client
    public var ios: Client

    public static let `default` = InnerTubeConfig(
        baseURL: URL(string: "https://www.youtube.com/youtubei/v1/")!,
        origin: URL(string: "https://www.youtube.com")!,
        hl: "en", gl: "US",
        web: Client(
            name: "WEB", nameID: 1, version: "2.20250101.00.00",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"),
        ios: Client(
            name: "IOS", nameID: 5, version: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82"))
}

struct InnerTubeBody: Encodable {
    struct ClientContext: Encodable {
        let clientName: String
        let clientVersion: String
        let hl: String
        let gl: String
        let deviceMake: String?
        let deviceModel: String?
        let osName: String?
        let osVersion: String?
    }
    struct Context: Encodable { let client: ClientContext }

    let context: Context
    var videoId: String?
    var query: String?
    var params: String?
    var browseId: String?
    var continuation: String?
    var contentCheckOk: Bool?
    var racyCheckOk: Bool?

    init(client: InnerTubeConfig.Client, config: InnerTubeConfig) {
        context = Context(client: ClientContext(
            clientName: client.name, clientVersion: client.version, hl: config.hl, gl: config.gl,
            deviceMake: client.deviceMake, deviceModel: client.deviceModel, osName: client.osName, osVersion: client.osVersion))
    }
}
