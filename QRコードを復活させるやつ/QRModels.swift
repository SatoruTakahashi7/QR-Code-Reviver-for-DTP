import Foundation

enum QRProcessingMode: String, CaseIterable, Identifiable {
    case reconstructed = "復元モード"
    case regenerated = "再生成モード"

    var id: String { rawValue }
}

enum QRErrorCorrectionLevel: String, CaseIterable, Identifiable {
    case l = "L"
    case m = "M"
    case q = "Q"
    case h = "H"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .l: return "L（約7%）"
        case .m: return "M（約15%）"
        case .q: return "Q（約25%）"
        case .h: return "H（約30%）"
        }
    }
}

enum QRValidationStatus: String {
    case notChecked = "未検証"
    case success = "OK"
    case warning = "注意"
    case failed = "NG"
}

struct QRAnalysisResult {
    var content: String
    var version: Int?
    var bodyCellCount: Int?
    var outputCellCount: Int?
    var errorCorrectionLevel: QRErrorCorrectionLevel?
    var maskPattern: Int?
    var contrastScore: Double?
    var ambiguousCellCount: Int?
    var decodeEngine: String
    var decodeNote: String
    var quietZoneCells: Int
    var outputSizeMillimeters: Double?
    var mode: QRProcessingMode
    var validationStatus: QRValidationStatus

    static let empty = QRAnalysisResult(
        content: "-",
        version: nil,
        bodyCellCount: nil,
        outputCellCount: nil,
        errorCorrectionLevel: nil,
        maskPattern: nil,
        contrastScore: nil,
        ambiguousCellCount: nil,
        decodeEngine: "-",
        decodeNote: "-",
        quietZoneCells: 4,
        outputSizeMillimeters: nil,
        mode: .regenerated,
        validationStatus: .notChecked
    )
}

struct QRMatrix {
    let cells: [[Bool]]

    var bodyCellCount: Int {
        cells.count
    }

    var isSquare: Bool {
        guard let first = cells.first else { return false }
        return cells.allSatisfy { $0.count == first.count } && first.count == cells.count
    }

    func withQuietZone(_ quietZone: Int) -> [[Bool]] {
        let bodySize = bodyCellCount
        let outputSize = bodySize + quietZone * 2

        var output = Array(
            repeating: Array(repeating: false, count: outputSize),
            count: outputSize
        )

        for y in 0..<bodySize {
            for x in 0..<bodySize {
                output[y + quietZone][x + quietZone] = cells[y][x]
            }
        }

        return output
    }
    
    func toggledCell(x: Int, y: Int) -> QRMatrix {
        guard y >= 0, y < cells.count else { return self }
        guard x >= 0, x < cells[y].count else { return self }

        var newCells = cells
        newCells[y][x].toggle()

        return QRMatrix(cells: newCells)
    }
    
}

struct QRRecoveredMatrixResult {
    let matrix: QRMatrix
    let contrastScore: Double
    let ambiguousCellCount: Int
    let ambiguousCells: Set<QRCellCoordinate>
    let note: String
}

struct QRCellCoordinate: Hashable {
    let x: Int
    let y: Int
}
