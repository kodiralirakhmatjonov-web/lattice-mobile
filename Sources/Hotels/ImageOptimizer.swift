import UIKit

enum ImageOptimizer {
    /// Hotel media is normalized before R2 upload so hundreds of gallery photos remain
    /// practical while still looking sharp on modern iPhone screens.
    static func jpegData(
        from data: Data,
        maxDimension: CGFloat = 1440,
        quality: CGFloat = 0.78,
        targetBytes: Int = 450_000
    ) throws -> Data {
        guard let source = UIImage(data: data) else { throw APIError.server("IMAGE_DECODE_FAILED") }

        let normalized = resized(source, maxDimension: maxDimension)
        var best: Data?

        for value in [quality, 0.74, 0.70, 0.66, 0.62, 0.58] {
            guard let encoded = normalized.jpegData(compressionQuality: value) else { continue }
            best = encoded
            if encoded.count <= targetBytes { return encoded }
        }

        let compact = resized(normalized, maxDimension: 1180)
        for value in [CGFloat(0.70), 0.64, 0.58, 0.54] {
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
