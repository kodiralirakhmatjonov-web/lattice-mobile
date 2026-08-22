import UIKit

enum ImageOptimizer {
    static func jpegData(from data: Data, maxDimension: CGFloat = 1800, quality: CGFloat = 0.82) throws -> Data {
        guard let image = UIImage(data: data) else { throw APIError.server("IMAGE_DECODE_FAILED") }
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: quality) else { throw APIError.server("IMAGE_ENCODE_FAILED") }
        return jpeg
    }
}
