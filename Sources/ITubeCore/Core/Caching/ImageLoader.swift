import Foundation
import ImageIO
import UIKit

/// Downloads, downsamples and caches thumbnails entirely off the main thread (ADR §41, §42).
public actor ImageLoader {
    private let http: any HTTPClient
    private let cache = NSCache<NSString, UIImage>()

    public init(http: any HTTPClient, memoryLimitBytes: Int = 48 * 1024 * 1024) {
        self.http = http
        cache.totalCostLimit = memoryLimitBytes
        cache.countLimit = 300
    }

    public func image(for url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        let pixel = max(32, (maxPixelSize / 32).rounded(.up) * 32)   // bucket sizes so cache keys are reusable
        let key = "\(url.absoluteString)#\(Int(pixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad   // thumbnails are immutable; URLCache is the disk layer
        let (data, _) = try await http.data(for: request)
        try Task.checkCancellation()
        guard let image = await Self.downsample(data: data, maxPixelSize: pixel) else { throw HTTPError.invalidResponse }
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    public func removeAll() { cache.removeAllObjects() }

    @concurrent
    private static func downsample(data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,      // decode now, here, not lazily on the main thread
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}
