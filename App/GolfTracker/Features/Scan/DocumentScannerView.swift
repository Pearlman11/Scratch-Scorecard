import SwiftUI
import UIKit
import VisionKit
import AVFoundation
import Photos

/// Wraps `VNDocumentCameraViewController`.
///
/// Using the system document scanner rather than a bare camera is the single highest-value decision in the
/// capture path: it gives edge detection, perspective correction, cropping and orientation for free, all
/// tuned by Apple against far more documents than this app will ever see. A card that arrives already
/// rectified is a dramatically easier parse than one photographed at an angle, so the processing pipeline
/// is told to skip its own rectangle detection for these.
struct DocumentScannerView: UIViewControllerRepresentable {

    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onError: onError)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([UIImage]) -> Void
        private let onCancel: () -> Void
        private let onError: (Error) -> Void

        init(
            onFinish: @escaping ([UIImage]) -> Void,
            onCancel: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true) { self.onFinish(images) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) { self.onCancel() }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true) { self.onError(error) }
        }
    }
}

/// Camera and photo-library authorisation, in the terms the scan screen needs.
///
/// Permission is requested at the moment the golfer taps to scan, never on launch: asking for a camera
/// before anyone has said they want to take a photo is how an app gets denied on the first prompt and then
/// has no path back.
enum CapturePermissions {

    enum Status {
        case authorized
        case denied
        case restricted
        case notDetermined
    }

    static var isDocumentScannerAvailable: Bool {
        VNDocumentCameraViewController.isSupported
    }

    static func cameraStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Photo-library status for *read* access.
    ///
    /// `PhotosPicker` runs out of process and needs no authorization at all, which is why importing works
    /// even when this reports denied. It is checked only to explain the situation if something else fails.
    static func photoLibraryStatus() -> Status {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}
