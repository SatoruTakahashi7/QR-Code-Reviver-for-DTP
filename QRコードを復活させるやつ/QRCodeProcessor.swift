import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

enum QRProcessingError: LocalizedError {
    case imageLoadFailed
    case noQRCodeDetected
    case noPayloadFound
    case qrGenerationFailed
    case bitmapExtractionFailed
    case invalidMatrix

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            return "画像を読み込めませんでした。"
        case .noQRCodeDetected:
            return "QRコードを検出できませんでした。"
        case .noPayloadFound:
            return "QRコードの内容を取得できませんでした。"
        case .qrGenerationFailed:
            return "QRコードの生成に失敗しました。"
        case .bitmapExtractionFailed:
            return "QRコード画像の解析に失敗しました。"
        case .invalidMatrix:
            return "QRコードのセル情報が不正です。"
        }
    }
}

final class QRCodeProcessor {
    private let ciContext = CIContext(options: nil)

    func loadCGImage(from url: URL) throws -> CGImage {
        guard
            let nsImage = NSImage(contentsOf: url),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw QRProcessingError.imageLoadFailed
        }

        return cgImage
    }

    func decodeQRCode(from cgImage: CGImage) throws -> String {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw QRProcessingError.noQRCodeDetected
        }

        let payloads = observations.compactMap { $0.payloadStringValue }

        guard let firstPayload = payloads.first, !firstPayload.isEmpty else {
            throw QRProcessingError.noPayloadFound
        }

        return firstPayload
    }

    func generateMatrix(
        from content: String,
        errorCorrectionLevel: QRErrorCorrectionLevel
    ) throws -> QRMatrix {
        let data = Data(content.utf8)

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = errorCorrectionLevel.rawValue

        guard let outputImage = filter.outputImage else {
            throw QRProcessingError.qrGenerationFailed
        }

        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw QRProcessingError.qrGenerationFailed
        }

        let rawMatrix = try extractBooleanMatrix(from: cgImage)
        let trimmedMatrix = trimWhiteBorder(from: rawMatrix)

        guard !trimmedMatrix.isEmpty, trimmedMatrix.count == trimmedMatrix.first?.count else {
            throw QRProcessingError.invalidMatrix
        }

        return QRMatrix(cells: trimmedMatrix)
    }

    func makePreviewImage(
        matrix: QRMatrix,
        quietZone: Int,
        scale: Int = 8
    ) throws -> NSImage {
        let cells = matrix.withQuietZone(quietZone)
        let cellCount = cells.count
        let pixelSize = cellCount * scale

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 255, count: pixelSize * pixelSize)

        for y in 0..<cellCount {
            for x in 0..<cellCount {
                let value: UInt8 = cells[y][x] ? 0 : 255

                for yy in 0..<scale {
                    for xx in 0..<scale {
                        let px = x * scale + xx
                        let py = y * scale + yy
                        pixels[py * pixelSize + px] = value
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw QRProcessingError.bitmapExtractionFailed
        }

        guard let cgImage = CGImage(
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: pixelSize,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw QRProcessingError.bitmapExtractionFailed
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: pixelSize, height: pixelSize))
    }

    func makeAnalysisResult(
        content: String,
        matrix: QRMatrix,
        errorCorrectionLevel: QRErrorCorrectionLevel,
        quietZone: Int,
        cellSizeMillimeters: Double
    ) -> QRAnalysisResult {
        let bodyCells = matrix.bodyCellCount
        let outputCells = bodyCells + quietZone * 2
        let version = inferVersion(fromBodyCellCount: bodyCells)
        let outputSize = Double(outputCells) * cellSizeMillimeters

        return QRAnalysisResult(
            content: content,
            version: version,
            bodyCellCount: bodyCells,
            outputCellCount: outputCells,
            errorCorrectionLevel: errorCorrectionLevel,
            maskPattern: nil,
            contrastScore: nil,
            ambiguousCellCount: nil,
            decodeEngine: "Vision + Core Image",
            decodeNote: "元画像から内容を読み取り、同じ内容でQRコードを再生成しました。見た目のパターンは元画像と異なる場合があります。",
            quietZoneCells: quietZone,
            outputSizeMillimeters: outputSize,
            mode: .regenerated,
            validationStatus: .success
        )
    }

    private func inferVersion(fromBodyCellCount cellCount: Int) -> Int? {
        guard cellCount >= 21 else { return nil }
        let difference = cellCount - 21
        guard difference % 4 == 0 else { return nil }

        let version = difference / 4 + 1
        guard version >= 1 && version <= 40 else { return nil }

        return version
    }

    private func extractBooleanMatrix(from cgImage: CGImage) throws -> [[Bool]] {
        let width = cgImage.width
        let height = cgImage.height

        guard width > 0, height > 0 else {
            throw QRProcessingError.bitmapExtractionFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 255, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw QRProcessingError.bitmapExtractionFailed
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var matrix = Array(
            repeating: Array(repeating: false, count: width),
            count: height
        )

        for y in 0..<height {
            for x in 0..<width {
                let luminance = pixels[y * width + x]
                matrix[y][x] = luminance < 128
            }
        }

        return matrix
    }

    private func trimWhiteBorder(from matrix: [[Bool]]) -> [[Bool]] {
        guard !matrix.isEmpty, let width = matrix.first?.count, width > 0 else {
            return matrix
        }

        let height = matrix.count

        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                if matrix[y][x] {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return matrix
        }

        var trimmed: [[Bool]] = []

        for y in minY...maxY {
            let row = Array(matrix[y][minX...maxX])
            trimmed.append(row)
        }

        return trimmed
    }
}
