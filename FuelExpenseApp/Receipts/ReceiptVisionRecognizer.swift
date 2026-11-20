import ImageIO
import UIKit
import Vision

enum ReceiptVisionRecognizer {
    static func recognize(in image: UIImage) async throws -> ReceiptData {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let image = try normalizedThumbnail(from: image)
                    guard let cgImage = image.cgImage else {
                        throw ReceiptScanError.unsupportedImage
                    }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                    request.minimumTextHeight = 0.005

                    let availableLanguages = try VNRecognizeTextRequest.supportedRecognitionLanguages(
                        for: .accurate,
                        revision: VNRecognizeTextRequest.currentRevision
                    )
                    let preferredLanguages = ["bg-BG", "en-US", "en-GB"]
                        .filter { availableLanguages.contains($0) }
                    request.recognitionLanguages = preferredLanguages.isEmpty
                        ? availableLanguages
                        : preferredLanguages

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])

                    let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
                        guard let text = observation.topCandidates(1).first else { return nil }
                        return OCRTextLine(
                            text: text.string,
                            confidence: Double(text.confidence),
                            top: observation.boundingBox.maxY,
                            left: observation.boundingBox.minX
                        )
                    }

                    guard !lines.isEmpty else { throw ReceiptScanError.noText }
                    let receipt = ReceiptParser().parse(lines)
                    guard receipt.hasRecognizedFields else {
                        throw ReceiptScanError.noReceiptFields
                    }
                    continuation.resume(returning: receipt)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func normalizedThumbnail(from image: UIImage) throws -> UIImage {
        guard let sourceImage = image.cgImage else {
            throw ReceiptScanError.unsupportedImage
        }

        let sourceWidth = CGFloat(sourceImage.width)
        let sourceHeight = CGFloat(sourceImage.height)
        let isSideways = image.imageOrientation == .left
            || image.imageOrientation == .leftMirrored
            || image.imageOrientation == .right
            || image.imageOrientation == .rightMirrored
        let orientedWidth = isSideways ? sourceHeight : sourceWidth
        let orientedHeight = isSideways ? sourceWidth : sourceHeight
        let scale = min(1, 2400 / max(orientedWidth, orientedHeight))
        let outputSize = CGSize(
            width: max(1, (orientedWidth * scale).rounded()),
            height: max(1, (orientedHeight * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }
}

enum ReceiptImageDownsampler {
    static func downsample(fileAt url: URL, maxPixelSize: Int = 2400) throws -> UIImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReceiptScanError.unsupportedImage
        }
        return UIImage(cgImage: thumbnail)
    }
}
