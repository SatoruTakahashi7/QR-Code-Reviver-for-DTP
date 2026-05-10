import AppKit
import Foundation

enum QRExportError: LocalizedError {
    case invalidMatrix
    case writeFailed
    case pdfContextFailed

    var errorDescription: String? {
        switch self {
        case .invalidMatrix:
            return "QRコードのセル情報が不正です。"
        case .writeFailed:
            return "ファイルの書き出しに失敗しました。"
        case .pdfContextFailed:
            return "PDFの作成に失敗しました。"
        }
    }
}

struct SVGExporter {
    static func export(
        matrix: QRMatrix,
        quietZone: Int,
        cellSizeMillimeters: Double,
        to url: URL
    ) throws {
        guard matrix.isSquare else {
            throw QRExportError.invalidMatrix
        }

        let cells = matrix.withQuietZone(quietZone)
        let outputCells = cells.count
        let sizeMillimeters = Double(outputCells) * cellSizeMillimeters

        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg"
             width="\(format(sizeMillimeters))mm"
             height="\(format(sizeMillimeters))mm"
             viewBox="0 0 \(format(sizeMillimeters)) \(format(sizeMillimeters))">
          <rect x="0" y="0" width="\(format(sizeMillimeters))" height="\(format(sizeMillimeters))" fill="#FFFFFF"/>

        """

        for y in 0..<outputCells {
            for x in 0..<outputCells where cells[y][x] {
                let rectX = Double(x) * cellSizeMillimeters
                let rectY = Double(y) * cellSizeMillimeters

                svg += """
                  <rect x="\(format(rectX))" y="\(format(rectY))" width="\(format(cellSizeMillimeters))" height="\(format(cellSizeMillimeters))" fill="#000000"/>

                """
            }
        }

        svg += "</svg>\n"

        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw QRExportError.writeFailed
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

struct PDFExporter {
    static func export(
        matrix: QRMatrix,
        quietZone: Int,
        cellSizeMillimeters: Double,
        to url: URL
    ) throws {
        guard matrix.isSquare else {
            throw QRExportError.invalidMatrix
        }

        let cells = matrix.withQuietZone(quietZone)
        let outputCells = cells.count

        let cellSizePoints = millimetersToPoints(cellSizeMillimeters)
        let pageSizePoints = Double(outputCells) * cellSizePoints

        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: pageSizePoints,
            height: pageSizePoints
        )

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw QRExportError.pdfContextFailed
        }

        context.beginPDFPage(nil)

        // DeviceGray:
        // gray 1.0 = 白
        // gray 0.0 = 黒
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(mediaBox)

        context.setFillColor(gray: 0.0, alpha: 1.0)

        for y in 0..<outputCells {
            for x in 0..<outputCells where cells[y][x] {
                let rectX = Double(x) * cellSizePoints

                // PDFは原点が左下なので、Y座標を反転する
                let rectY = pageSizePoints - Double(y + 1) * cellSizePoints

                let rect = CGRect(
                    x: rectX,
                    y: rectY,
                    width: cellSizePoints,
                    height: cellSizePoints
                )

                context.fill(rect)
            }
        }

        context.endPDFPage()
        context.closePDF()
    }

    private static func millimetersToPoints(_ millimeters: Double) -> Double {
        millimeters * 72.0 / 25.4
    }
}
