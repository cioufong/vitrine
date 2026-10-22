import AVFoundation
import CoreVideo
import Foundation
import VitrineAgentProtocol

/// The Mac's camera as packed YUYV frames for a guest's virtual camera. Runs only between `start`
/// and `stop`, so the camera light is on exactly while a VM is being given the camera.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        case accessDenied, noCamera, configuration(String)
        public var errorDescription: String? {
            switch self {
            case .accessDenied: return "Vitrine isn't allowed to use the camera (System Settings ▸ Privacy & Security ▸ Camera)."
            case .noCamera: return "No camera is connected to this Mac."
            case .configuration(let s): return "The camera couldn't be started: \(s)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.github.cioufong.vitrine.camera")
    private let onFrame: (CameraFrame) -> Void
    /// Told once what the camera actually delivers, e.g. "1280×720 2vuy" (for the VM log).
    public var onFormat: ((String) -> Void)?
    private var reportedFormat = false
    private let gate = NSLock()
    private var delivering = true

    /// `onFrame` is called on a private queue.
    public init(onFrame: @escaping (CameraFrame) -> Void) {
        self.onFrame = onFrame
    }

    /// Asks for camera access the first time (needs NSCameraUsageDescription in the app's Info.plist).
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Opens the camera without delivering frames yet (blocks briefly; call off the main thread).
    /// Returns the frame size, so the guest can be told before the first frame arrives.
    public func prepare() throws -> (width: Int, height: Int) {
        guard let device = AVCaptureDevice.default(for: .video) else { throw Failure.noCamera }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw Failure.configuration(error.localizedDescription) }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw Failure.configuration("input") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        guard session.canAddOutput(output) else { throw Failure.configuration("output") }
        session.addOutput(output)
        // Only now do the preset and the output's formats reflect this camera.
        let hd = session.canSetSessionPreset(.hd1280x720)
        session.sessionPreset = hd ? .hd1280x720 : .vga640x480
        let size = hd ? (width: 1280, height: 720) : (width: 640, height: 480)
        let yuvs = kCVPixelFormatType_422YpCbCr8_yuvs, uyvy = kCVPixelFormatType_422YpCbCr8
        // Both packed 4:2:2 layouts are handled per frame; ask for the one that needs no swapping.
        let format = output.availableVideoPixelFormatTypes.contains(yuvs) ? yuvs : uyvy
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                kCVPixelBufferWidthKey as String: size.width,
                                kCVPixelBufferHeightKey as String: size.height]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        // Frames of another size are still sent, with their own dimensions; the guest adapts.
        return size
    }

    /// Starts delivering frames (blocks briefly; call off the main thread).
    public func run() {
        session.startRunning()
    }

    public func stop() {
        stopDelivering()
        session.stopRunning()
    }

    /// Ends `onFrame` calls for good, at once: when this returns, none is running or will start,
    /// so whatever the caller sends next (the guest's camera stop) follows the last frame.
    /// `stop` still has to turn the camera off, which takes a while.
    public func stopDelivering() {
        gate.withLock { delivering = false }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)
        if !reportedFormat {
            reportedFormat = true
            onFormat?("\(w)×\(h) \(Self.fourCC(format))")
        }
        // 'yuvs' is YUYV already; '2vuy' is UYVY and gets each byte pair swapped. Anything else
        // (a camera that ignored the requested format) isn't packed 4:2:2 and is dropped.
        let swap: Bool
        switch format {
        case kCVPixelFormatType_422YpCbCr8_yuvs: swap = false
        case kCVPixelFormatType_422YpCbCr8: swap = true
        default: return
        }
        guard let base = CVPixelBufferGetBaseAddress(pb), w > 0, h > 0, w % 2 == 0, stride >= w * 2,
              w <= Int(CameraFrame.maxDimension), h <= Int(CameraFrame.maxDimension) else { return }
        let row = w * 2
        var data = Data(count: row * h)
        data.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            guard let out = dst.baseAddress else { return }
            for y in 0..<h { memcpy(out + y * row, base + y * stride, row) }
            if swap {
                // UYVY → YUYV: swap each byte pair.
                let p = out.assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i + 1 < row * h { let t = p[i]; p[i] = p[i + 1]; p[i + 1] = t; i += 2 }
            }
        }
        let frame = CameraFrame(width: UInt32(w), height: UInt32(h), data: data)
        gate.withLock { if delivering { onFrame(frame) } }
    }

    static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
}
