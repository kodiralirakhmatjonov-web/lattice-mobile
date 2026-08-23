import UIKit

enum ImageOptimizer {
    /// Optimizes imported hotel media before it ever reaches Cloudflare R2.
    /// The goal is a sharp full-screen iPhone image without storing multi-megabyte OTA originals.
    static func jpegData(
        from data: Data,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.80,
        targetBytes: Int = 650_000
    ) throws -> Data {
        guard let source = UIImage(data: data) else { throw APIError.server("IMAGE_DECODE_FAILED") }

        let normalized = resized(source, maxDimension: maxDimension)
        let qualities: [CGFloat] = [quality, 0.76, 0.72, 0.68, 0.64, 0.60]
        var best: Data?

        for value in qualities {
            guard let encoded = normalized.jpegData(compressionQuality: value) else { continue }
            best = encoded
            if encoded.count <= targetBytes { return encoded }
        }

        // Very detailed photos can still be large. A second, slightly smaller pass keeps
        // R2 usage predictable while preserving enough resolution for the app UI.
        let compact = resized(normalized, maxDimension: 1280)
        for value in [CGFloat(0.72), 0.66, 0.60, 0.56] {
            guard let encoded = compact.jpegData(compressionQuality: value) else { continue }
            best = encoded
            if encoded.count <= targetBytes { return encoded }
        }

        guard let best else { throw APIError.server("IMAGE_ENCODE_FAILED") }
        return best
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }

        let scale = maxDimension / longest
        let target = CGSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
