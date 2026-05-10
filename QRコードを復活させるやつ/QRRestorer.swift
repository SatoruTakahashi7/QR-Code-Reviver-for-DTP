import AppKit
import CoreImage
import Foundation
import Vision

enum QRRestoreError: LocalizedError {
    case noQRCodeDetected
    case perspectiveCorrectionFailed
    case imageCreationFailed
    case bitmapExtractionFailed
    case invalidCellCount
    case matrixExtractionFailed

    var errorDescription: String? {
        switch self {
        case .noQRCodeDetected:
            return "正面化できるQRコードを検出できませんでした。"
        case .perspectiveCorrectionFailed:
            return "QRコードの正面化に失敗しました。"
        case .imageCreationFailed:
            return "正面化画像の作成に失敗しました。"
        case .bitmapExtractionFailed:
            return "画像のピクセル情報を取得できませんでした。"
        case .invalidCellCount:
            return "QRコードのセル数を推定できませんでした。"
        case .matrixExtractionFailed:
            return "QRコードのセル配列を抽出できませんでした。"
        }
    }
}

struct QRRectificationResult {
    let image: NSImage
    let cgImage: CGImage
    let note: String
}

final class QRRestorer {
    private let ciContext = CIContext(options: nil)

    func rectifyQRCode(from cgImage: CGImage) throws -> QRRectificationResult {
        let observation = try detectQRCodeObservation(from: cgImage)

        let ciImage = CIImage(cgImage: cgImage)
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        let topLeft = convertVisionPoint(observation.topLeft, width: imageWidth, height: imageHeight)
        let topRight = convertVisionPoint(observation.topRight, width: imageWidth, height: imageHeight)
        let bottomLeft = convertVisionPoint(observation.bottomLeft, width: imageWidth, height: imageHeight)
        let bottomRight = convertVisionPoint(observation.bottomRight, width: imageWidth, height: imageHeight)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw QRRestoreError.perspectiveCorrectionFailed
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage else {
            throw QRRestoreError.perspectiveCorrectionFailed
        }

        guard let correctedCGImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw QRRestoreError.imageCreationFailed
        }

        let nsImage = NSImage(
            cgImage: correctedCGImage,
            size: NSSize(width: correctedCGImage.width, height: correctedCGImage.height)
        )

        return QRRectificationResult(
            image: nsImage,
            cgImage: correctedCGImage,
            note: "VisionでQRコードの四隅を検出し、正面化しました。"
        )
    }

    func recoverMatrix(
        from rectifiedCGImage: CGImage,
        expectedBodyCellCount: Int?
    ) throws -> QRRecoveredMatrixResult {
        let gray = try makeGrayBitmap(from: rectifiedCGImage)

        // 正面化画像にはクワイエットゾーンや余白が含まれることがあるため、
        // 黒セルの外接範囲を使ってQR本体らしい範囲に絞る。
        let croppedGray = cropToBlackBounds(from: gray) ?? gray

        let detectedCellCount: Int
        if let expectedBodyCellCount {
            detectedCellCount = expectedBodyCellCount
        } else {
            detectedCellCount = try estimateBodyCellCount(from: croppedGray)
        }

        guard detectedCellCount >= 21, detectedCellCount <= 177 else {
            throw QRRestoreError.invalidCellCount
        }

        let result = try extractMatrix(
            gray: croppedGray,
            cellCount: detectedCellCount
        )

        return result
    }

    private func detectQRCodeObservation(from cgImage: CGImage) throws -> VNBarcodeObservation {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw QRRestoreError.noQRCodeDetected
        }

        let qrObservations = observations.filter { $0.symbology == .qr }

        guard let bestObservation = qrObservations.max(by: { area(of: $0.boundingBox) < area(of: $1.boundingBox) }) else {
            throw QRRestoreError.noQRCodeDetected
        }

        return bestObservation
    }

    private func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private func convertVisionPoint(_ point: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * width,
            y: point.y * height
        )
    }

    private struct GrayBitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func valueAt(x: Int, y: Int) -> UInt8 {
            let clampedX = min(max(x, 0), width - 1)
            let clampedY = min(max(y, 0), height - 1)
            return pixels[clampedY * width + clampedX]
        }
    }

    private func makeGrayBitmap(from cgImage: CGImage) throws -> GrayBitmap {
        let width = cgImage.width
        let height = cgImage.height

        guard width > 0, height > 0 else {
            throw QRRestoreError.bitmapExtractionFailed
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
            throw QRRestoreError.bitmapExtractionFailed
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return GrayBitmap(width: width, height: height, pixels: pixels)
    }
    
    private func cropToBlackBounds(from gray: GrayBitmap) -> GrayBitmap? {
        guard gray.width > 0, gray.height > 0 else {
            return nil
        }

        // ざっくり二値化するためのしきい値。
        // 画像が薄い場合もあるので、完全な黒だけではなく 180 未満を黒候補にする。
        let blackThreshold: UInt8 = 180

        var minX = gray.width
        var minY = gray.height
        var maxX = -1
        var maxY = -1

        for y in 0..<gray.height {
            for x in 0..<gray.width {
                let value = gray.valueAt(x: x, y: y)

                if value < blackThreshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let detectedWidth = maxX - minX + 1
        let detectedHeight = maxY - minY + 1

        // あまりに小さい検出は誤検出として捨てる
        guard detectedWidth >= 10, detectedHeight >= 10 else {
            return nil
        }

        // 外接範囲を正方形にする。
        // QR本体は正方形なので、長い辺に合わせる。
        let side = max(detectedWidth, detectedHeight)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        var startX = centerX - side / 2
        var startY = centerY - side / 2

        startX = max(0, min(startX, gray.width - side))
        startY = max(0, min(startY, gray.height - side))

        let endX = min(gray.width - 1, startX + side - 1)
        let endY = min(gray.height - 1, startY + side - 1)

        let croppedWidth = endX - startX + 1
        let croppedHeight = endY - startY + 1

        guard croppedWidth > 0, croppedHeight > 0 else {
            return nil
        }

        var croppedPixels = [UInt8]()
        croppedPixels.reserveCapacity(croppedWidth * croppedHeight)

        for y in startY...endY {
            for x in startX...endX {
                croppedPixels.append(gray.valueAt(x: x, y: y))
            }
        }

        return GrayBitmap(
            width: croppedWidth,
            height: croppedHeight,
            pixels: croppedPixels
        )
    }

    private func estimateBodyCellCount(from gray: GrayBitmap) throws -> Int {
        let candidates = (1...40).map { 21 + 4 * ($0 - 1) }

        let best = candidates.max { lhs, rhs in
            finderPatternScore(gray: gray, cellCount: lhs) < finderPatternScore(gray: gray, cellCount: rhs)
        }

        guard let best else {
            throw QRRestoreError.invalidCellCount
        }

        return best
    }

    private func finderPatternScore(gray: GrayBitmap, cellCount: Int) -> Double {
        let finderSize = 7
        let positions = [
            (x: 0, y: 0),
            (x: cellCount - finderSize, y: 0),
            (x: 0, y: cellCount - finderSize)
        ]

        var totalScore = 0.0

        for position in positions {
            for y in 0..<finderSize {
                for x in 0..<finderSize {
                    let moduleX = position.x + x
                    let moduleY = position.y + y

                    let expectedBlack: Bool

                    if x == 0 || x == 6 || y == 0 || y == 6 {
                        expectedBlack = true
                    } else if x == 1 || x == 5 || y == 1 || y == 5 {
                        expectedBlack = false
                    } else {
                        expectedBlack = true
                    }

                    let value = sampleCellAverage(gray: gray, cellCount: cellCount, cellX: moduleX, cellY: moduleY)
                    let actualBlack = value < 128

                    if actualBlack == expectedBlack {
                        totalScore += 1.0
                    }
                }
            }
        }

        return totalScore
    }

    private func extractMatrix(
        gray: GrayBitmap,
        cellCount: Int
    ) throws -> QRRecoveredMatrixResult {
        guard cellCount > 0 else {
            throw QRRestoreError.matrixExtractionFailed
        }

        var sampledValues: [[Double]] = []
        sampledValues.reserveCapacity(cellCount)

        var blackValues: [Double] = []
        var whiteValues: [Double] = []

        for y in 0..<cellCount {
            var row: [Double] = []
            row.reserveCapacity(cellCount)

            for x in 0..<cellCount {
                let value = sampleCellAverage(gray: gray, cellCount: cellCount, cellX: x, cellY: y)
                row.append(value)

                if value < 128 {
                    blackValues.append(value)
                } else {
                    whiteValues.append(value)
                }
            }

            sampledValues.append(row)
        }

        let blackAverage = blackValues.isEmpty ? 0.0 : blackValues.reduce(0, +) / Double(blackValues.count)
        let whiteAverage = whiteValues.isEmpty ? 255.0 : whiteValues.reduce(0, +) / Double(whiteValues.count)

        let threshold = (blackAverage + whiteAverage) / 2.0
        let contrastScore = max(0, min(1, (whiteAverage - blackAverage) / 255.0))

        let ambiguityBand = max(12.0, (whiteAverage - blackAverage) * 0.12)

        var ambiguousCount = 0
        var ambiguousCells = Set<QRCellCoordinate>()

        var cells = Array(
            repeating: Array(repeating: false, count: cellCount),
            count: cellCount
        )

        for y in 0..<cellCount {
            for x in 0..<cellCount {
                let value = sampledValues[y][x]

                if abs(value - threshold) <= ambiguityBand {
                    ambiguousCount += 1
                    ambiguousCells.insert(QRCellCoordinate(x: x, y: y))
                }

                cells[y][x] = value < threshold
            }
        }

        let note = "正面化QRから \(cellCount) × \(cellCount) セルとして白黒セル配列を抽出しました。"

        return QRRecoveredMatrixResult(
            matrix: QRMatrix(cells: cells),
            contrastScore: contrastScore,
            ambiguousCellCount: ambiguousCount,
            ambiguousCells: ambiguousCells,
            note: note
        )
    }

    private func sampleCellAverage(
        gray: GrayBitmap,
        cellCount: Int,
        cellX: Int,
        cellY: Int
    ) -> Double {
        let cellWidth = Double(gray.width) / Double(cellCount)
        let cellHeight = Double(gray.height) / Double(cellCount)

        let centerX = (Double(cellX) + 0.5) * cellWidth
        let centerY = (Double(cellY) + 0.5) * cellHeight

        let sampleRadiusX = max(1, Int(cellWidth * 0.22))
        let sampleRadiusY = max(1, Int(cellHeight * 0.22))

        var sum = 0.0
        var count = 0

        for yy in -sampleRadiusY...sampleRadiusY {
            for xx in -sampleRadiusX...sampleRadiusX {
                let x = Int(centerX) + xx
                let y = Int(centerY) + yy
                sum += Double(gray.valueAt(x: x, y: y))
                count += 1
            }
        }

        return count > 0 ? sum / Double(count) : 255.0
    }
}
