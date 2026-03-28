import SwiftUI
import PhotosUI

struct ReceiptScannerView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let onComplete: () async -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var capturedImage: UIImage?
    @State private var isAnalyzing = false
    @State private var analysisResult: ReceiptAnalysis?
    @State private var error: String?

    // User editable fields
    @State private var selectedAccountId: String?
    @State private var selectedCategoryId: String?
    @State private var transactionDate = Date()
    @State private var isFinalizing = false

    @State private var showCamera = false

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        NavigationStack {
            Group {
                if isAnalyzing {
                    analyzeProgressView
                } else if let result = analysisResult {
                    resultView(result)
                } else {
                    captureView
                }
            }
            .navigationTitle(String(localized: "receipt.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
            }
        }
        .onChange(of: selectedPhoto) {
            Task { await loadSelectedPhoto() }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                capturedImage = image
                showCamera = false
                Task { await analyzeImage(image) }
            }
        }
    }

    // MARK: - Capture View

    private var captureView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(Color.accent)

            Text(String(localized: "receipt.instruction"))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(String(localized: "receipt.instructionDetail"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    showCamera = true
                } label: {
                    Label(String(localized: "receipt.takePhoto"), systemImage: "camera.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(String(localized: "receipt.fromGallery"), systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .foregroundStyle(Color.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Progress View

    private var analyzeProgressView: some View {
        VStack(spacing: 20) {
            Spacer()
            if let img = capturedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)
            }
            ProgressView()
                .scaleEffect(1.5)
            Text(String(localized: "receipt.analyzing"))
                .font(.headline)
            Text(String(localized: "receipt.analyzingDetail"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Result View

    private func resultView(_ result: ReceiptAnalysis) -> some View {
        Form {
            if let merchant = result.merchantName {
                Section(String(localized: "receipt.merchant")) {
                    Text(merchant)
                        .font(.headline)
                }
            }

            Section(String(localized: "common.amount")) {
                HStack {
                    Text(appViewModel.currencyManager.formatAmount(Decimal(result.totalAmount)))
                        .font(.title2.weight(.bold))
                    Spacer()
                    if let conf = result.confidence {
                        Text("\(Int(conf * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let summary = result.summary {
                Section(String(localized: "receipt.items")) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "common.account")) {
                Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                    Text(String(localized: "budget.allAccounts")).tag(nil as String?)
                    ForEach(dataStore.accounts) { acc in
                        Text("\(acc.icon) \(acc.name)").tag(acc.id as String?)
                    }
                }
            }

            Section(String(localized: "common.category")) {
                Picker(String(localized: "common.category"), selection: $selectedCategoryId) {
                    ForEach(dataStore.categories.filter { $0.type == .expense }) { cat in
                        Text("\(cat.icon) \(cat.name)").tag(cat.id as String?)
                    }
                }
            }

            Section {
                DatePicker(String(localized: "common.date"), selection: $transactionDate, displayedComponents: .date)
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                Button {
                    Task { await finalizeReceipt(result) }
                } label: {
                    HStack {
                        Spacer()
                        if isFinalizing {
                            ProgressView()
                        } else {
                            Text(String(localized: "receipt.saveTransaction"))
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(isFinalizing)
            }
        }
    }

    // MARK: - Logic

    private func loadSelectedPhoto() async {
        guard let item = selectedPhoto else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            error = String(localized: "receipt.loadError")
            return
        }
        capturedImage = image
        await analyzeImage(image)
    }

    private func analyzeImage(_ image: UIImage) async {
        let resized = resizeImage(image, maxSize: 1800)
        guard let jpegData = resized.jpegData(compressionQuality: 0.82) else {
            error = String(localized: "receipt.compressError")
            return
        }

        isAnalyzing = true
        error = nil

        do {
            let result = try await uploadAndAnalyze(imageData: jpegData)
            analysisResult = result

            // Pre-fill with suggestions
            selectedAccountId = result.suggestedAccountId ?? dataStore.accounts.first(where: { $0.isPrimary })?.id
            selectedCategoryId = result.suggestedCategoryId ?? result.categoryId

            if let dateStr = result.purchaseDate {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                if let d = df.date(from: dateStr) { transactionDate = d }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isAnalyzing = false
    }

    private func uploadAndAnalyze(imageData: Data) async throws -> ReceiptAnalysis {
        let supabase = SupabaseManager.shared.client
        let session = try await supabase.auth.session

        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"receipt.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let url = URL(string: "\(AppConstants.supabaseURL)/functions/v1/analyze-receipt")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConstants.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode(AnalyzeReceiptResponse.self, from: data)

        guard result.ok else {
            throw NSError(domain: "receipt", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: result.error ?? "Analysis failed"])
        }

        return result.analysis!
    }

    private func finalizeReceipt(_ result: ReceiptAnalysis) async {
        guard let scanId = result.receiptScanId else {
            error = "Missing receipt scan ID"
            return
        }

        isFinalizing = true
        error = nil

        do {
            let supabase = SupabaseManager.shared.client
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"

            struct FinalizeInput: Encodable {
                let receipt_scan_id: String
                let accountId: String?
                let categoryId: String?
                let transactionDate: String?
            }

            let _: FinalizeReceiptResponse = try await supabase.functions.invoke(
                "finalize-receipt",
                options: .init(body: FinalizeInput(
                    receipt_scan_id: scanId,
                    accountId: selectedAccountId,
                    categoryId: selectedCategoryId,
                    transactionDate: df.string(from: transactionDate)
                ))
            )

            await onComplete()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }

        isFinalizing = false
    }

    private func resizeImage(_ image: UIImage, maxSize: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(maxSize / size.width, maxSize / size.height)
        guard ratio < 1 else { return image }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - Response Models

struct AnalyzeReceiptResponse: Decodable {
    let ok: Bool
    let error: String?
    let analysis: ReceiptAnalysis?
}

struct ReceiptAnalysis: Decodable {
    let merchantName: String?
    let purchaseDate: String?
    let totalAmount: Double
    let totalAmountRub: Double?
    let currency: String?
    let categoryHint: String?
    let summary: String?
    let confidence: Double?
    let categoryId: String?
    let receiptScanId: String?
    let suggestedAccountId: String?
    let suggestedCategoryId: String?

    enum CodingKeys: String, CodingKey {
        case merchantName = "merchant_name"
        case purchaseDate = "purchase_date"
        case totalAmount = "total_amount"
        case totalAmountRub = "total_amount_rub"
        case currency
        case categoryHint = "category_hint"
        case summary, confidence
        case categoryId = "category_id"
        case receiptScanId = "receipt_scan_id"
        case suggestedAccountId = "suggested_account_id"
        case suggestedCategoryId = "suggested_category_id"
    }
}

struct FinalizeReceiptResponse: Decodable {
    let ok: Bool
    let receiptScanId: String?
    let duplicate: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case receiptScanId = "receipt_scan_id"
        case duplicate
    }
}

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void

        init(onCapture: @escaping (UIImage) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
