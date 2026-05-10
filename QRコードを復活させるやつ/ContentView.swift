import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private let processor = QRCodeProcessor()
    private let restorer = QRRestorer()
    private let quietZoneCells = 4
    
    @State private var sourceImage: NSImage?
    @State private var rectifiedSourceImage: NSImage?
    @State private var rectifiedImage: NSImage?
    @State private var outputImage: NSImage?

    @State private var candidateMatrix: QRMatrix?
    @State private var recoveredMatrix: QRMatrix?
    @State private var regeneratedMatrix: QRMatrix?

    @State private var ambiguousCells: Set<QRCellCoordinate> = []
    @State private var candidateUndoStack: [QRMatrix] = []
    @State private var isCandidateEditorPresented = false
    
    @State private var analysisResult: QRAnalysisResult = .empty
    
    @State private var selectedCellSizeMillimeters: Double = 0.25
    @State private var selectedErrorCorrectionLevel: QRErrorCorrectionLevel = .q
    
    @State private var statusMessage: String = "画像を選んでください。"
    @State private var isProcessing = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            HStack(spacing: 18) {
                previewPanel
                
                VStack(spacing: 14) {
                    settingsPanel
                    infoPanel
                    exportPanel
                }
                .frame(width: 420)
            }
            .padding(20)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isCandidateEditorPresented) {
            if let candidateMatrix {
                CandidateQREditorSheet(
                    matrix: candidateMatrix,
                    ambiguousCells: ambiguousCells,
                    rectifiedSourceImage: rectifiedSourceImage,
                    content: analysisResult.content,
                    validationStatus: analysisResult.validationStatus,
                    canExportRecoveredQR: recoveredMatrix != nil,
                    canUndo: !candidateUndoStack.isEmpty,
                    statusMessage: statusMessage,
                    decodeNote: analysisResult.decodeNote,
                    onToggleCell: { x, y in
                        toggleCandidateCell(x: x, y: y)
                    },
                    onUndo: {
                        undoCandidateEdit()
                    },
                    onExportSVG: {
                        exportRecoveredSVG()
                    },
                    onExportPDF: {
                        exportRecoveredPDF()
                    },
                    onClose: {
                        isCandidateEditorPresented = false
                    }
                )
                .frame(minWidth: 760, minHeight: 820)
            } else {
                VStack(spacing: 16) {
                    Text("復元候補QRがありません")
                        .font(.headline)

                    Button("閉じる") {
                        isCandidateEditorPresented = false
                    }
                }
                .frame(width: 360, height: 180)
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("QRコードを復活させるやつ")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                selectImage()
            } label: {
                Text("画像を選ぶ")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    private var previewPanel: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                imageBox(title: "元画像", image: sourceImage)

                candidateQRBox

                imageBox(title: "再生成QR", image: outputImage)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("読み取り内容")
                    .font(.headline)
                
                ScrollView {
                    Text(analysisResult.content)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 96)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                )
            }
            
            Spacer()
        }
    }
    
    private func imageBox(title: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
                
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.25))
                
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(16)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        
                        Text("未選択")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
        }
    }
    
    private var candidateQRBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("復元候補QR")
                    .font(.headline)

                Spacer()

                if candidateMatrix != nil {
                    Text("クリックして拡大編集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))

                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.25))

                if let candidateMatrix {
                    Button {
                        isCandidateEditorPresented = true
                    } label: {
                        QRMatrixPreviewView(
                            matrix: candidateMatrix,
                            ambiguousCells: ambiguousCells
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .padding(16)
                    }
                    .buttonStyle(.plain)
                    .help("クリックすると大きな編集パネルを開きます")
                } else if let rectifiedImage {
                    Button {
                        isCandidateEditorPresented = true
                    } label: {
                        Image(nsImage: rectifiedImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .aspectRatio(1, contentMode: .fit)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)

                        Text("未作成")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
        }
    }
    
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("設定")
                .font(.headline)
            
            Picker("セルサイズ", selection: $selectedCellSizeMillimeters) {
                Text("0.25mm").tag(0.25)
                Text("0.28mm").tag(0.28)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedCellSizeMillimeters) {
                regenerateIfPossible()
            }
            
            Picker("誤り訂正", selection: $selectedErrorCorrectionLevel) {
                ForEach(QRErrorCorrectionLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedErrorCorrectionLevel) {
                regenerateIfPossible()
            }
            
            HStack {
                Text("クワイエットゾーン")
                Spacer()
                Text("\(quietZoneCells)セル")
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                Text("処理モード")
                Spacer()
                Text(analysisResult.mode.rawValue)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("情報")
                .font(.headline)
                .padding(.bottom, 8)
            
            infoRow("Content", analysisResult.content)
            infoRow("Version", valueOrDash(analysisResult.version.map { "\($0)" }))
            infoRow("Cells", cellText)
            infoRow("Error correction", analysisResult.errorCorrectionLevel?.rawValue ?? "-")
            infoRow("Mask", valueOrDash(analysisResult.maskPattern.map { "\($0)" }))
            infoRow("Contrast", contrastText)
            infoRow("Ambiguous cells", valueOrDash(analysisResult.ambiguousCellCount.map { "\($0)" }))
            infoRow("Decode engine", analysisResult.decodeEngine)
            infoRow("Decode note", analysisResult.decodeNote)
            infoRow("Quiet zone", "\(analysisResult.quietZoneCells)セル")
            infoRow("Output cells", outputCellsText)
            infoRow("Output size", outputSizeText)
            infoRow("Validation", analysisResult.validationStatus.rawValue)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("書き出し")
                .font(.headline)

            HStack(spacing: 8) {
                Button {
                    exportRecoveredSVG()
                } label: {
                    Text("復元QRをSVGで書き出す")
                        .frame(maxWidth: .infinity)
                }
                .disabled(recoveredMatrix == nil)

                Button {
                    exportRecoveredPDF()
                } label: {
                    Text("復元QRをPDFで書き出す")
                        .frame(maxWidth: .infinity)
                }
                .disabled(recoveredMatrix == nil)
            }

            HStack(spacing: 8) {
                Button {
                    exportRegeneratedSVG()
                } label: {
                    Text("再生成QRをSVGで書き出す")
                        .frame(maxWidth: .infinity)
                }
                .disabled(regeneratedMatrix == nil)

                Button {
                    exportRegeneratedPDF()
                } label: {
                    Text("再生成QRをPDFで書き出す")
                        .frame(maxWidth: .infinity)
                }
                .disabled(regeneratedMatrix == nil)
            }

            if recoveredMatrix == nil {
                Text("復元QRは、復元候補QRの再読取が元画像の内容と一致した場合だけ書き出せます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                
                Text(value.isEmpty ? "-" : value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))
            .padding(.vertical, 7)
            
            Divider()
        }
    }
    
    private var cellText: String {
        guard let count = analysisResult.bodyCellCount else { return "-" }
        return "\(count) × \(count)"
    }
    
    private var outputCellsText: String {
        guard let count = analysisResult.outputCellCount else { return "-" }
        return "\(count) × \(count)"
    }
    
    private var outputSizeText: String {
        guard let size = analysisResult.outputSizeMillimeters else { return "-" }
        return String(format: "%.2fmm × %.2fmm", size, size)
    }
    
    private var contrastText: String {
        guard let contrast = analysisResult.contrastScore else { return "-" }
        return String(format: "%.2f", contrast)
    }
    
    private func valueOrDash(_ value: String?) -> String {
        value ?? "-"
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            return false
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, error in
                if let error {
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
                
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    DispatchQueue.main.async {
                        self.errorMessage = "ドロップされたファイルを読み込めませんでした。"
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.processImage(url: url)
                }
            }
            
            return true
        }
        
        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { object, error in
                if let error {
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
                
                guard let image = object as? NSImage else {
                    DispatchQueue.main.async {
                        self.errorMessage = "ドロップされた画像を読み込めませんでした。"
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.processDroppedImage(image)
                }
            }
            
            return true
        }
        
        return false
    }
    
    private func processDroppedImage(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "ドロップされた画像を処理できませんでした。"
            return
        }
        
        processCGImage(cgImage, sourceImage: image)
    }
    
    private func selectImage() {
        let panel = NSOpenPanel()
        panel.title = "QRコード画像を選択"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .image]
        
        if panel.runModal() == .OK, let url = panel.url {
            processImage(url: url)
        }
    }
    
    private func processImage(url: URL) {
        isProcessing = true
        statusMessage = "処理中です..."
        
        do {
            let cgImage = try processor.loadCGImage(from: url)
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            
            processCGImage(cgImage, sourceImage: image)
        } catch {
            statusMessage = "読み取りに失敗しました。"
            errorMessage = error.localizedDescription
            isProcessing = false
        }
    }
    
    private func processCGImage(_ cgImage: CGImage, sourceImage image: NSImage) {
        isProcessing = true
        statusMessage = "処理中です..."

        do {
            sourceImage = image
            rectifiedSourceImage = nil
            rectifiedImage = nil
            candidateMatrix = nil
            recoveredMatrix = nil
            regeneratedMatrix = nil
            ambiguousCells = []
            candidateUndoStack = []

            let content = try processor.decodeQRCode(from: cgImage)

            let newRegeneratedMatrix = try processor.generateMatrix(
                from: content,
                errorCorrectionLevel: selectedErrorCorrectionLevel
            )

            let regeneratedPreview = try processor.makePreviewImage(
                matrix: newRegeneratedMatrix,
                quietZone: quietZoneCells,
                scale: 8
            )

            var finalAnalysisMatrix = newRegeneratedMatrix
            var mode: QRProcessingMode = .regenerated
            var contrastScore: Double?
            var ambiguousCellCount: Int?
            var validationStatus: QRValidationStatus = .success

            var restoreNote = """
            復元候補QRはまだ作成されていません。
            再生成QRを作成しました。
            """

            do {
                let rectified = try restorer.rectifyQRCode(from: cgImage)

                rectifiedSourceImage = rectified.image

                let recovered = try restorer.recoverMatrix(
                    from: rectified.cgImage,
                    expectedBodyCellCount: nil
                )

                let recoveredPreview = try processor.makePreviewImage(
                    matrix: recovered.matrix,
                    quietZone: quietZoneCells,
                    scale: 8
                )

                // 復元候補QRは、検証OK/NGに関係なく中央に表示する。
                // 以後は candidateMatrix をクリック編集対象にする。
                candidateMatrix = recovered.matrix
                rectifiedImage = recoveredPreview
                ambiguousCells = recovered.ambiguousCells

                contrastScore = recovered.contrastScore
                ambiguousCellCount = recovered.ambiguousCellCount

                guard let recoveredCGImage = recoveredPreview.cgImage(
                    forProposedRect: nil,
                    context: nil,
                    hints: nil
                ) else {
                    throw QRProcessingError.bitmapExtractionFailed
                }

                let recoveredContent = try processor.decodeQRCode(from: recoveredCGImage)

                if recoveredContent == content {
                    // 復元候補QRが元画像と同じ内容として読めた場合だけ、
                    // 復元QRとして書き出し可能にする
                    recoveredMatrix = recovered.matrix
                    finalAnalysisMatrix = recovered.matrix
                    mode = .reconstructed
                    validationStatus = .success

                    restoreNote = """
                    \(rectified.note)
                    \(recovered.note)
                    復元候補QRを再読取し、元画像の内容と一致しました。
                    復元QRとして書き出し可能です。
                    """
                } else {
                    // 復元候補は表示するが、書き出しは不可
                    recoveredMatrix = nil
                    finalAnalysisMatrix = newRegeneratedMatrix
                    mode = .regenerated
                    validationStatus = .warning

                    restoreNote = """
                    \(rectified.note)
                    \(recovered.note)

                    復元候補QRの再読取結果が元画像と一致しませんでした。
                    復元候補QRは画面には表示しますが、復元QRとしては書き出せません。
                    安全のため、再生成QRのみ書き出し可能です。

                    元画像:
                    \(content)

                    復元候補QR:
                    \(recoveredContent)
                    """
                }
            } catch {
                // 復元候補そのものが作れなかった場合
                recoveredMatrix = nil
                rectifiedImage = nil
                finalAnalysisMatrix = newRegeneratedMatrix
                mode = .regenerated
                validationStatus = .warning

                restoreNote = """
                復元候補QRの作成に失敗しました。
                安全のため、再生成QRのみ書き出し可能です。

                理由:
                \(error.localizedDescription)
                """
            }

            regeneratedMatrix = newRegeneratedMatrix
            outputImage = regeneratedPreview

            analysisResult = processor.makeAnalysisResult(
                content: content,
                matrix: finalAnalysisMatrix,
                errorCorrectionLevel: selectedErrorCorrectionLevel,
                quietZone: quietZoneCells,
                cellSizeMillimeters: selectedCellSizeMillimeters
            )

            analysisResult.mode = mode
            analysisResult.contrastScore = contrastScore
            analysisResult.ambiguousCellCount = ambiguousCellCount
            analysisResult.decodeNote = restoreNote
            analysisResult.decodeEngine = mode == .reconstructed
                ? "Vision + Core Image + Cell Restore"
                : "Vision + Core Image"
            analysisResult.validationStatus = validationStatus

            statusMessage = mode == .reconstructed
                ? "復元QRを書き出せます。"
                : "復元候補QRは表示していますが、書き出しは再生成QRのみ有効です。"
        } catch {
            statusMessage = "読み取りに失敗しました。"
            errorMessage = error.localizedDescription
        }

        isProcessing = false
    }
    
    private func regenerateIfPossible() {
        guard analysisResult.content != "-", !analysisResult.content.isEmpty else {
            return
        }

        do {
            let matrix = try processor.generateMatrix(
                from: analysisResult.content,
                errorCorrectionLevel: selectedErrorCorrectionLevel
            )

            let preview = try processor.makePreviewImage(
                matrix: matrix,
                quietZone: quietZoneCells,
                scale: 8
            )

            // 誤り訂正レベルの変更は、再生成QRだけに反映する
            regeneratedMatrix = matrix
            outputImage = preview
            candidateUndoStack = []

            // 復元QRが検証OKなら、それを基準に情報表示を維持する
            // 復元QRがなければ、再生成QRを基準にする
            let displayMatrix = recoveredMatrix ?? matrix

            let previousMode = analysisResult.mode
            let previousContrast = analysisResult.contrastScore
            let previousAmbiguous = analysisResult.ambiguousCellCount
            let previousNote = analysisResult.decodeNote
            let previousEngine = analysisResult.decodeEngine
            let previousValidation = analysisResult.validationStatus

            analysisResult = processor.makeAnalysisResult(
                content: analysisResult.content,
                matrix: displayMatrix,
                errorCorrectionLevel: selectedErrorCorrectionLevel,
                quietZone: quietZoneCells,
                cellSizeMillimeters: selectedCellSizeMillimeters
            )

            // 復元QRが残っている場合は、復元状態を維持する
            if recoveredMatrix != nil {
                analysisResult.mode = previousMode
                analysisResult.contrastScore = previousContrast
                analysisResult.ambiguousCellCount = previousAmbiguous
                analysisResult.decodeNote = previousNote
                analysisResult.decodeEngine = previousEngine
                analysisResult.validationStatus = previousValidation
                statusMessage = "再生成QRの設定を反映しました。復元候補QRは維持しています。"
            } else {
                analysisResult.mode = .regenerated
                analysisResult.validationStatus = .success
                statusMessage = "再生成QRの設定を反映しました。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func toggleCandidateCell(x: Int, y: Int) {
        guard let currentMatrix = candidateMatrix else { return }

        pushCandidateUndo(currentMatrix)

        let updatedMatrix = currentMatrix.toggledCell(x: x, y: y)
        candidateMatrix = updatedMatrix

        ambiguousCells.remove(QRCellCoordinate(x: x, y: y))

        validateEditedCandidateMatrix(updatedMatrix)
    }
    
    private func pushCandidateUndo(_ matrix: QRMatrix) {
        candidateUndoStack.append(matrix)

        // 履歴が増えすぎないように、最大100件までにする
        if candidateUndoStack.count > 100 {
            candidateUndoStack.removeFirst(candidateUndoStack.count - 100)
        }
    }

    private func undoCandidateEdit() {
        guard let previousMatrix = candidateUndoStack.popLast() else {
            statusMessage = "戻せる操作がありません。"
            return
        }

        candidateMatrix = previousMatrix
        rectifiedImage = try? processor.makePreviewImage(
            matrix: previousMatrix,
            quietZone: quietZoneCells,
            scale: 8
        )

        validateEditedCandidateMatrix(previousMatrix)

        statusMessage = "1つ前の状態に戻しました。"
    }
    
    private func validateEditedCandidateMatrix(_ matrix: QRMatrix) {
        guard analysisResult.content != "-", !analysisResult.content.isEmpty else {
            recoveredMatrix = nil
            return
        }

        do {
            let preview = try processor.makePreviewImage(
                matrix: matrix,
                quietZone: quietZoneCells,
                scale: 8
            )

            rectifiedImage = preview

            guard let candidateCGImage = preview.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ) else {
                throw QRProcessingError.bitmapExtractionFailed
            }

            let candidateContent = try processor.decodeQRCode(from: candidateCGImage)

            if candidateContent == analysisResult.content {
                recoveredMatrix = matrix
                analysisResult.mode = .reconstructed
                analysisResult.validationStatus = .success
                analysisResult.decodeEngine = "Vision + Core Image + Cell Restore + Manual Edit"
                analysisResult.decodeNote = """
                復元候補QRを手動修正しました。
                修正後の復元候補QRを再読取し、元画像の内容と一致しました。
                復元QRとして書き出し可能です。
                """
                statusMessage = "手動修正により、復元QRを書き出せるようになりました。"
            } else {
                recoveredMatrix = nil
                analysisResult.mode = .regenerated
                analysisResult.validationStatus = .warning
                analysisResult.decodeEngine = "Vision + Core Image + Cell Restore + Manual Edit"
                analysisResult.decodeNote = """
                復元候補QRを手動修正しましたが、まだ元画像の内容と一致していません。

                元画像:
                \(analysisResult.content)

                現在の復元候補QR:
                \(candidateContent)
                """
                statusMessage = "まだ元画像の内容と一致していません。復元QRの書き出しは無効です。"
            }
        } catch {
            recoveredMatrix = nil
            analysisResult.mode = .regenerated
            analysisResult.validationStatus = .failed
            analysisResult.decodeEngine = "Vision + Core Image + Cell Restore + Manual Edit"
            analysisResult.decodeNote = """
            復元候補QRを手動修正しましたが、現在の復元候補QRは読み取れません。

            理由:
            \(error.localizedDescription)
            """
            statusMessage = "現在の復元候補QRは読み取れません。復元QRの書き出しは無効です。"
        }
    }
    
    private func exportRecoveredSVG() {
        exportSVG(
            matrix: recoveredMatrix,
            defaultFileName: "recovered_qr.svg",
            missingMessage: "復元QRがありません。復元モードで検証OKになった場合だけ書き出せます。"
        )
    }

    private func exportRecoveredPDF() {
        exportPDF(
            matrix: recoveredMatrix,
            defaultFileName: "recovered_qr.pdf",
            missingMessage: "復元QRがありません。復元モードで検証OKになった場合だけ書き出せます。"
        )
    }

    private func exportRegeneratedSVG() {
        exportSVG(
            matrix: regeneratedMatrix,
            defaultFileName: "regenerated_qr.svg",
            missingMessage: "再生成QRがありません。先にQR画像を読み込んでください。"
        )
    }

    private func exportRegeneratedPDF() {
        exportPDF(
            matrix: regeneratedMatrix,
            defaultFileName: "regenerated_qr.pdf",
            missingMessage: "再生成QRがありません。先にQR画像を読み込んでください。"
        )
    }

    private func exportSVG(
        matrix: QRMatrix?,
        defaultFileName: String,
        missingMessage: String
    ) {
        guard let matrix else {
            errorMessage = missingMessage
            return
        }

        let panel = NSSavePanel()
        panel.title = "SVGを書き出す"
        panel.nameFieldStringValue = defaultFileName
        panel.allowedFileTypes = ["svg"]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let result = panel.runModal()

        guard result == .OK, let url = panel.url else {
            statusMessage = "SVG書き出しをキャンセルしました。"
            return
        }

        do {
            try SVGExporter.export(
                matrix: matrix,
                quietZone: quietZoneCells,
                cellSizeMillimeters: selectedCellSizeMillimeters,
                to: url
            )

            statusMessage = "SVGを書き出しました：\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportPDF(
        matrix: QRMatrix?,
        defaultFileName: String,
        missingMessage: String
    ) {
        guard let matrix else {
            errorMessage = missingMessage
            return
        }

        let panel = NSSavePanel()
        panel.title = "PDFを書き出す"
        panel.nameFieldStringValue = defaultFileName
        panel.allowedFileTypes = ["pdf"]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let result = panel.runModal()

        guard result == .OK, let url = panel.url else {
            statusMessage = "PDF書き出しをキャンセルしました。"
            return
        }

        do {
            try PDFExporter.export(
                matrix: matrix,
                quietZone: quietZoneCells,
                cellSizeMillimeters: selectedCellSizeMillimeters,
                to: url
            )

            statusMessage = "PDFを書き出しました：\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct QRMatrixPreviewView: View {
    let matrix: QRMatrix
    let ambiguousCells: Set<QRCellCoordinate>
    let quietZone: Int = 4

    var body: some View {
        GeometryReader { geometry in
            let bodyCellCount = matrix.bodyCellCount
            let displayCellCount = bodyCellCount + quietZone * 2
            let side = min(geometry.size.width, geometry.size.height)
            let cellSize = side / CGFloat(max(displayCellCount, 1))
            let originX = (geometry.size.width - side) / 2
            let originY = (geometry.size.height - side) / 2

            ZStack {
                Color.white

                ForEach(0..<displayCellCount, id: \.self) { displayY in
                    ForEach(0..<displayCellCount, id: \.self) { displayX in
                        let bodyX = displayX - quietZone
                        let bodyY = displayY - quietZone

                        let isInsideBody =
                            bodyX >= 0 &&
                            bodyY >= 0 &&
                            bodyX < bodyCellCount &&
                            bodyY < bodyCellCount

                        let isBlack = isInsideBody ? matrix.cells[bodyY][bodyX] : false

                        Rectangle()
                            .fill(isBlack ? Color.black : Color.white)
                            .frame(width: cellSize, height: cellSize)
                            .position(
                                x: originX + CGFloat(displayX) * cellSize + cellSize / 2,
                                y: originY + CGFloat(displayY) * cellSize + cellSize / 2
                            )

                        if isInsideBody && ambiguousCells.contains(QRCellCoordinate(x: bodyX, y: bodyY)) {
                            ZStack {
                                Rectangle()
                                    .fill(Color.red.opacity(0.28))

                                Rectangle()
                                    .stroke(Color.yellow.opacity(0.95), lineWidth: max(1.2, cellSize * 0.10))

                                Rectangle()
                                    .stroke(Color.red.opacity(0.95), lineWidth: max(0.8, cellSize * 0.05))
                            }
                            .frame(width: cellSize, height: cellSize)
                            .position(
                                x: originX + CGFloat(displayX) * cellSize + cellSize / 2,
                                y: originY + CGFloat(displayY) * cellSize + cellSize / 2
                            )
                        }
                    }
                }

                // QR本体範囲の枠
                Rectangle()
                    .stroke(Color.blue.opacity(0.45), lineWidth: 1)
                    .frame(
                        width: CGFloat(bodyCellCount) * cellSize,
                        height: CGFloat(bodyCellCount) * cellSize
                    )
                    .position(
                        x: originX + CGFloat(quietZone) * cellSize + CGFloat(bodyCellCount) * cellSize / 2,
                        y: originY + CGFloat(quietZone) * cellSize + CGFloat(bodyCellCount) * cellSize / 2
                    )

                // クワイエットゾーン込みの外枠
                Rectangle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}

struct CandidateQREditorSheet: View {
    let matrix: QRMatrix
    let ambiguousCells: Set<QRCellCoordinate>
    let rectifiedSourceImage: NSImage?
    let content: String
    let validationStatus: QRValidationStatus
    let canExportRecoveredQR: Bool
    let canUndo: Bool
    let statusMessage: String
    let decodeNote: String
    let onToggleCell: (Int, Int) -> Void
    let onUndo: () -> Void
    let onExportSVG: () -> Void
    let onExportPDF: () -> Void
    let onClose: () -> Void

    @GestureState private var isPressingCompareButton = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("復元候補QRを編集")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("赤いセルは判定が怪しいセルです。セルをクリックすると黒白が反転し、自動で再読取します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("閉じる") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }

            editorStatusPanel

            editorComparePanel

            editorToolPanel

            editorExportPanel

            editorMainDisplay
                .frame(width: 680, height: 680)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.3))
                )

            HStack {
                Text("セル数：\(matrix.bodyCellCount) × \(matrix.bodyCellCount)")
                Spacer()
                Text("赤セル：\(ambiguousCells.count)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }
    
    private var editorComparePanel: some View {
        HStack(spacing: 10) {
            Text("押している間、正面化元QRを表示")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(rectifiedSourceImage == nil
                              ? Color.gray.opacity(0.18)
                              : Color.accentColor.opacity(isPressingCompareButton ? 0.32 : 0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .foregroundStyle(rectifiedSourceImage == nil ? .secondary : .primary)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isPressingCompareButton) { _, state, _ in
                            state = rectifiedSourceImage != nil
                        }
                )

            Text(isPressingCompareButton
                 ? "正面化元QRを表示中です。離すと復元候補QRに戻ります。"
                 : "通常時は復元候補QRを編集できます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    @ViewBuilder
    private var editorMainDisplay: some View {
        if isPressingCompareButton, let rectifiedSourceImage {
            RectifiedSourceCompareView(
                image: rectifiedSourceImage,
                matrix: matrix
            )
        } else {
            QRMatrixEditorView(
                matrix: matrix,
                ambiguousCells: ambiguousCells,
                onToggleCell: onToggleCell
            )
        }
    }
    
    private var editorToolPanel: some View {
        HStack(spacing: 10) {
            Button {
                onUndo()
            } label: {
                Text("1つ戻る")
                    .frame(minWidth: 120)
            }
            .disabled(!canUndo)
            .keyboardShortcut("z", modifiers: [.command])

            Text("セル修正を1操作戻します")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
    
    private var editorExportPanel: some View {
        HStack(spacing: 10) {
            Button {
                onExportSVG()
            } label: {
                Text("復元SVGを書き出す")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canExportRecoveredQR)

            Button {
                onExportPDF()
            } label: {
                Text("復元PDFを書き出す")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canExportRecoveredQR)
        }
    }
    
    private var editorStatusPanel: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("現在")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(statusLabel)
                    .font(.headline)
            }
            .frame(width: 130, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("書き出し")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(canExportRecoveredQR ? "復元QRを書き出せます" : "まだ復元QRは書き出せません")
                    .font(.headline)

                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(14)
        .background(panelBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(panelBorderColor.opacity(0.65), lineWidth: 1)
        )
    }

    private var statusLabel: String {
        switch validationStatus {
        case .success:
            return "OK"
        case .warning:
            return "注意"
        case .failed:
            return "読み取り不可"
        case .notChecked:
            return "未検証"
        }
    }

    private var panelBackgroundColor: Color {
        if canExportRecoveredQR {
            return Color.green.opacity(0.14)
        }

        switch validationStatus {
        case .failed:
            return Color.red.opacity(0.14)
        case .warning:
            return Color.yellow.opacity(0.16)
        case .notChecked:
            return Color.gray.opacity(0.12)
        case .success:
            return Color.green.opacity(0.14)
        }
    }

    private var panelBorderColor: Color {
        if canExportRecoveredQR {
            return Color.green
        }

        switch validationStatus {
        case .failed:
            return Color.red
        case .warning:
            return Color.yellow
        case .notChecked:
            return Color.gray
        case .success:
            return Color.green
        }
    }
}

struct QRMatrixEditorView: View {
    let matrix: QRMatrix
    let ambiguousCells: Set<QRCellCoordinate>
    let onToggleCell: (Int, Int) -> Void

    private let quietZone = 4

    var body: some View {
        GeometryReader { geometry in
            let bodyCellCount = matrix.bodyCellCount
            let displayCellCount = bodyCellCount + quietZone * 2
            let side = min(geometry.size.width, geometry.size.height)
            let cellSize = side / CGFloat(max(displayCellCount, 1))
            let originX = (geometry.size.width - side) / 2
            let originY = (geometry.size.height - side) / 2

            ZStack {
                Color.white

                ForEach(0..<displayCellCount, id: \.self) { displayY in
                    ForEach(0..<displayCellCount, id: \.self) { displayX in
                        let bodyX = displayX - quietZone
                        let bodyY = displayY - quietZone

                        let isInsideBody =
                            bodyX >= 0 &&
                            bodyY >= 0 &&
                            bodyX < bodyCellCount &&
                            bodyY < bodyCellCount

                        let isBlack = isInsideBody ? matrix.cells[bodyY][bodyX] : false

                        Rectangle()
                            .fill(isBlack ? Color.black : Color.white)
                            .frame(width: cellSize, height: cellSize)
                            .position(
                                x: originX + CGFloat(displayX) * cellSize + cellSize / 2,
                                y: originY + CGFloat(displayY) * cellSize + cellSize / 2
                            )

                        if isInsideBody && ambiguousCells.contains(QRCellCoordinate(x: bodyX, y: bodyY)) {
                            AmbiguousCellMarker(cellSize: cellSize)
                                .frame(width: cellSize, height: cellSize)
                                .position(
                                    x: originX + CGFloat(displayX) * cellSize + cellSize / 2,
                                    y: originY + CGFloat(displayY) * cellSize + cellSize / 2
                                )
                        }
                    }
                }

                gridLines(
                    cellCount: displayCellCount,
                    side: side,
                    cellSize: cellSize,
                    originX: originX,
                    originY: originY
                )

                // QR本体範囲。ここだけ編集対象。
                Rectangle()
                    .stroke(Color.blue.opacity(0.65), lineWidth: 2)
                    .frame(
                        width: CGFloat(bodyCellCount) * cellSize,
                        height: CGFloat(bodyCellCount) * cellSize
                    )
                    .position(
                        x: originX + CGFloat(quietZone) * cellSize + CGFloat(bodyCellCount) * cellSize / 2,
                        y: originY + CGFloat(quietZone) * cellSize + CGFloat(bodyCellCount) * cellSize / 2
                    )

                Rectangle()
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let localX = value.location.x - originX
                        let localY = value.location.y - originY

                        guard localX >= 0, localY >= 0, localX < side, localY < side else {
                            return
                        }

                        let displayX = Int(localX / cellSize)
                        let displayY = Int(localY / cellSize)

                        let bodyX = displayX - quietZone
                        let bodyY = displayY - quietZone

                        guard bodyX >= 0, bodyX < bodyCellCount, bodyY >= 0, bodyY < bodyCellCount else {
                            return
                        }

                        onToggleCell(bodyX, bodyY)
                    }
            )
        }
    }

    private func gridLines(
        cellCount: Int,
        side: CGFloat,
        cellSize: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) -> some View {
        Path { path in
            for index in 0...cellCount {
                let offset = CGFloat(index) * cellSize

                path.move(to: CGPoint(x: originX + offset, y: originY))
                path.addLine(to: CGPoint(x: originX + offset, y: originY + side))

                path.move(to: CGPoint(x: originX, y: originY + offset))
                path.addLine(to: CGPoint(x: originX + side, y: originY + offset))
            }
        }
        .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)
    }
}

struct AmbiguousCellMarker: View {
    let cellSize: CGFloat

    var body: some View {
        ZStack {
            // 色だけに頼らず、黒白どちらの上でも見えるようにする
            Rectangle()
                .fill(Color.purple.opacity(0.32))

            // 外側の白フチ
            Rectangle()
                .stroke(Color.white.opacity(0.95), lineWidth: max(1.2, cellSize * 0.12))

            // 内側の青紫フチ
            Rectangle()
                .stroke(Color.purple.opacity(0.95), lineWidth: max(1.0, cellSize * 0.07))

            // 斜めクロス：白
            Path { path in
                path.move(to: CGPoint(x: cellSize * 0.22, y: cellSize * 0.22))
                path.addLine(to: CGPoint(x: cellSize * 0.78, y: cellSize * 0.78))

                path.move(to: CGPoint(x: cellSize * 0.78, y: cellSize * 0.22))
                path.addLine(to: CGPoint(x: cellSize * 0.22, y: cellSize * 0.78))
            }
            .stroke(Color.white.opacity(0.95), lineWidth: max(1.0, cellSize * 0.10))

            // 斜めクロス：青紫を少し細く重ねる
            Path { path in
                path.move(to: CGPoint(x: cellSize * 0.22, y: cellSize * 0.22))
                path.addLine(to: CGPoint(x: cellSize * 0.78, y: cellSize * 0.78))

                path.move(to: CGPoint(x: cellSize * 0.78, y: cellSize * 0.22))
                path.addLine(to: CGPoint(x: cellSize * 0.22, y: cellSize * 0.78))
            }
            .stroke(Color.purple.opacity(0.95), lineWidth: max(0.7, cellSize * 0.055))
        }
    }
}

struct RectifiedSourceCompareView: View {
    let image: NSImage
    let matrix: QRMatrix

    private let quietZone = 4

    var body: some View {
        GeometryReader { geometry in
            let bodyCellCount = matrix.bodyCellCount
            let displayCellCount = bodyCellCount + quietZone * 2

            let side = min(geometry.size.width, geometry.size.height)
            let cellSize = side / CGFloat(max(displayCellCount, 1))

            let originX = (geometry.size.width - side) / 2
            let originY = (geometry.size.height - side) / 2

            let bodySide = CGFloat(bodyCellCount) * cellSize

            let bodyOriginX = originX + CGFloat(quietZone) * cellSize
            let bodyOriginY = originY + CGFloat(quietZone) * cellSize

            ZStack {
                Color.white

                // クワイエットゾーン込みの外枠
                Rectangle()
                    .fill(Color.white)
                    .frame(width: side, height: side)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )

                // 正面化元QR画像は、QR本体の青枠内に合わせて表示する
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: bodySide, height: bodySide)
                    .clipped()
                    .position(
                        x: bodyOriginX + bodySide / 2,
                        y: bodyOriginY + bodySide / 2
                    )

                // グリッド
                gridLines(
                    cellCount: displayCellCount,
                    side: side,
                    cellSize: cellSize,
                    originX: originX,
                    originY: originY
                )

                // QR本体範囲。復元候補QR側の青枠と同じ位置。
                Rectangle()
                    .stroke(Color.blue.opacity(0.65), lineWidth: 2)
                    .frame(width: bodySide, height: bodySide)
                    .position(
                        x: bodyOriginX + bodySide / 2,
                        y: bodyOriginY + bodySide / 2
                    )

                // クワイエットゾーン込みの外枠
                Rectangle()
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
            }
        }
    }

    private func gridLines(
        cellCount: Int,
        side: CGFloat,
        cellSize: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) -> some View {
        Path { path in
            for index in 0...cellCount {
                let offset = CGFloat(index) * cellSize

                path.move(to: CGPoint(x: originX + offset, y: originY))
                path.addLine(to: CGPoint(x: originX + offset, y: originY + side))

                path.move(to: CGPoint(x: originX, y: originY + offset))
                path.addLine(to: CGPoint(x: originX + side, y: originY + offset))
            }
        }
        .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)
    }
}
