import AppKit
import AVFoundation
import SwiftUI

/// 노치 미러: 내장 카메라 미리보기(좌우 반전). 뷰가 보일 때만 세션이 돈다.
struct CameraMirror: NSViewRepresentable {
    @MainActor static var isActive = false

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.start()
        return v
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.stop()
    }

    final class PreviewView: NSView {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dynamicnotch.camera")
        private let preview: AVCaptureVideoPreviewLayer
        private let label = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            preview.frame = bounds
            label.frame = bounds.insetBy(dx: 10, dy: bounds.height / 2 - 10)
        }

        func start() {
            CameraMirror.isActive = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async { ok ? self.configure() : self.show("카메라 권한이 없어요") }
                }
            default: show("시스템 설정 → 개인정보 보호 → 카메라에서 허용해 주세요")
            }
        }

        private func show(_ text: String) { label.stringValue = text }

        private func configure() {
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                             mediaType: .video, position: .unspecified)
            guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                show("카메라를 찾을 수 없어요"); return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if let c = preview.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
            queue.async { [session] in session.startRunning() }
        }

        func stop() {
            queue.async { [session] in session.stopRunning() }
            // 카메라가 완전히 꺼진 뒤에 감지를 다시 켠다
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { CameraMirror.isActive = false }
        }
    }
}
