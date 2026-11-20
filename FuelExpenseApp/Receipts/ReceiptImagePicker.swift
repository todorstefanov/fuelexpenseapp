import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReceiptCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onError: (Error) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onError: onError, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let onError: (Error) -> Void
        private let onCancel: () -> Void

        init(
            onImage: @escaping (UIImage) -> Void,
            onError: @escaping (Error) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onImage = onImage
            self.onError = onError
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                picker.dismiss(animated: true) {
                    self.onError(ReceiptScanError.unsupportedImage)
                }
                return
            }
            picker.dismiss(animated: true) {
                self.onImage(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) {
                self.onCancel()
            }
        }
    }
}

struct ReceiptPhotoLibraryPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onError: (Error) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onError: onError, onCancel: onCancel)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let onError: (Error) -> Void
        private let onCancel: () -> Void

        init(
            onImage: @escaping (UIImage) -> Void,
            onError: @escaping (Error) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onImage = onImage
            self.onError = onError
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                picker.dismiss(animated: true) {
                    self.onCancel()
                }
                return
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                picker.dismiss(animated: true) {
                    self.onError(ReceiptScanError.unsupportedImage)
                }
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url else {
                    DispatchQueue.main.async {
                        picker.dismiss(animated: true) {
                            self.onError(error ?? ReceiptScanError.unsupportedImage)
                        }
                    }
                    return
                }

                do {
                    let image = try ReceiptImageDownsampler.downsample(fileAt: url)
                    DispatchQueue.main.async {
                        picker.dismiss(animated: true) {
                            self.onImage(image)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        picker.dismiss(animated: true) {
                            self.onError(error)
                        }
                    }
                }
            }
        }
    }
}
