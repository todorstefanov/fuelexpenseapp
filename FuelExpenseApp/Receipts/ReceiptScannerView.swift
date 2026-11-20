import AVFoundation
import SwiftUI
import UIKit

struct ReceiptScannerView: View {
    let onReceipt: (ReceiptData) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isShowingCamera = false
    @State private var isShowingPhotoLibrary = false
    @State private var cameraMessage: String?
    @State private var scanState: ScanState = .ready

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Scan or choose a receipt image. Text recognition runs on this device.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(action: requestCamera) {
                            Label("Take Photo", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            isShowingPhotoLibrary = true
                        } label: {
                            Label("Choose Image", systemImage: "photo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(isProcessing)

                    if let cameraMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cameraMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                            HStack {
                                Button("Open Settings") {
                                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                                    openURL(settingsURL)
                                }
                                Button("Choose Image") {
                                    isShowingPhotoLibrary = true
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    stateContent
                }
                .padding()
            }
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isShowingCamera) {
            ReceiptCameraPicker(
                onImage: { image in
                    isShowingCamera = false
                    process(image)
                },
                onError: { error in
                    isShowingCamera = false
                    showError(error)
                },
                onCancel: {
                    isShowingCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingPhotoLibrary) {
            ReceiptPhotoLibraryPicker(
                onImage: { image in
                    isShowingPhotoLibrary = false
                    process(image)
                },
                onError: { error in
                    isShowingPhotoLibrary = false
                    showError(error)
                },
                onCancel: {
                    isShowingPhotoLibrary = false
                }
            )
            .ignoresSafeArea()
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var stateContent: some View {
        switch scanState {
        case .ready:
            EmptyView()
        case .processing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading receipt…")
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
        case .complete(let receipt):
            VStack(alignment: .leading, spacing: 10) {
                Label("Receipt scanned", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                if receipt.webFormValues.isEmpty {
                    Text("No fields could be safely added to the expense form. Review the receipt and enter the required values manually.")
                        .font(.callout)
                } else {
                    Text("Added: \(displayNames(for: receipt.webFormValues.keys))")
                        .font(.callout)
                    Text("Review the form and complete any required fields that remain empty.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !receipt.reviewLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(receipt.reviewLines, id: \.self) { line in
                            Text(line).font(.caption)
                        }
                    }
                }

                if receipt.fuelLineAmount != nil, receipt.webFormValues["price"] != nil {
                    Text(receipt.discountWasInferred
                        ? "The discount was estimated from the fuel amount and printed EUR total. Review the amount before saving."
                        : "The EUR amount uses the fuel-line amount minus the detected discount. Review it before saving.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if receipt.fuelLineAmount != nil {
                    Text("The fuel amount or discount could not be reconciled confidently. Enter the EUR total manually.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if receipt.totalAmount != nil,
                          receipt.currency != "EUR",
                          receipt.webFormValues["price"] == nil {
                    Text("The detected total is not in EUR, so the amount field was left unchanged.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn’t read this receipt", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                Text("Try a sharper, well-lit image with the entire receipt visible, or enter the values manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var isProcessing: Bool {
        if case .processing = scanState { return true }
        return false
    }

    private func requestCamera() {
        cameraMessage = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = "A camera is not available on this device. Choose an existing receipt image instead."
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isShowingCamera = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    isShowingCamera = true
                } else {
                    cameraMessage = "Camera access was denied. Enable it in Settings or choose an existing image."
                }
            }
        case .denied, .restricted:
            cameraMessage = "Camera access is unavailable. Enable it in Settings or choose an existing image."
        @unknown default:
            cameraMessage = "Camera access could not be checked. Choose an existing image instead."
        }
    }

    private func process(_ image: UIImage) {
        cameraMessage = nil
        scanState = .processing
        Task {
            do {
                let receipt = try await ReceiptVisionRecognizer.recognize(in: image)
                onReceipt(receipt)
                scanState = .complete(receipt)
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        if error is ReceiptScanError {
            scanState = .failed(error.localizedDescription)
        } else {
            scanState = .failed(
                "The image could not be processed (\(error.localizedDescription)). Choose another image or enter the values manually."
            )
        }
    }

    private func displayNames(for keys: Dictionary<String, String>.Keys) -> String {
        let names = keys.compactMap { key -> String? in
            switch key {
            case "expense_date": return "date"
            case "quantity": return "quantity"
            case "price": return "total"
            case "gas_station": return "station"
            case "fuel_brand": return "fuel product"
            case "fuel_type": return "fuel type"
            default: return nil
            }
        }
        return names.joined(separator: ", ")
    }
}

private enum ScanState {
    case ready
    case processing
    case complete(ReceiptData)
    case failed(String)
}
