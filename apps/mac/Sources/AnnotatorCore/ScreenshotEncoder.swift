import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotError: Error, Equatable, CustomStringConvertible {
    case encodingFailed
    case tooLarge

    public var description: String {
        switch self {
        case .encodingFailed: "Could not encode the screenshot as JPEG."
        case .tooLarge: "The screenshot is too large to send, even after downscaling."
        }
    }
}

/// Encodes captures as JPEG data URLs that fit in the server's request limit.
public enum ScreenshotEncoder {
    /// The server rejects requests over 10 MiB.
    public static let requestLimit = 10 * 1024 * 1024
    /// Room left for the rest of the record (comment, path, metadata).
    public static let recordReserve = 256 * 1024

    public static let prefix = "data:image/jpeg;base64,"

    /// Returns a data URL of at most `maxBytes` characters.
    /// Halves the pixel count until it fits; fails loudly if it never does.
    public static func dataURL(
        for image: CGImage,
        quality: Double = 0.8,
        maxBytes: Int = requestLimit - recordReserve
    ) throws -> String {
        var current = image
        for _ in 0..<8 {
            let jpeg = try encodeJPEG(current, quality: quality)
            let length = prefix.utf8.count + base64Length(jpeg.count)
            if length <= maxBytes { return prefix + jpeg.base64EncodedString() }
            guard let smaller = scale(current, by: 0.7071) else { throw ScreenshotError.encodingFailed }
            current = smaller
        }
        throw ScreenshotError.tooLarge
    }

    static func base64Length(_ bytes: Int) -> Int { (bytes + 2) / 3 * 4 }

    static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ScreenshotError.encodingFailed }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.encodingFailed }
        return data as Data
    }

    static func scale(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
