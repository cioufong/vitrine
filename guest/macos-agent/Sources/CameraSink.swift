import Accelerate
import CoreMediaIO
import CoreVideo
import Foundation
import SystemExtensions
import VitrineAgentProtocol

/// Feeds the host Mac's camera frames into the "Vitrine Camera" extension
/// (guest/macos-camera-extension), which apps in this guest see as an ordinary camera.
/// Main-thread confined.
final class CameraSink: NSObject, OSSystemExtensionRequestDelegate {
    /// scripts/build-agent.sh names the extension after the agent's own bundle identifier.
    static let extensionIdentifier = (Bundle.main.bundleIdentifier ?? "io.github.cioufong.vitrine.agent") + ".camera"
    static let deviceName = "Vitrine Camera"
    static let sinkStreamName = "Vitrine Camera Input"
    /// The one format the extension advertises; frames of any other size are scaled to it.
    static let width = 1280, height = 720

    /// This agent carries the camera extension (agents built without it don't announce "camera").
    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension").path)
    }

    var onLog: ((String) -> Void)?
    private var device: CMIOObjectID = 0
    private var stream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var pool: CVPixelBufferPool?
    private var format: CMFormatDescription?

    private enum Activation { case none, pending, needsApproval, failed(String), done }
    private var activation = Activation.none

    /// Opens the extension's input stream, activating the extension first if needed.
    func start(_ request: CameraStart) -> CameraStatus {
        stop()
        guard Self.isBundled else {
            return CameraStatus(ready: false, error: "this Vitrine agent was built without its camera extension", installable: false)
        }
        guard let (device, stream) = Self.findSink() else {
            guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                return CameraStatus(ready: false, error: "macOS adds camera extensions only for apps in /Applications, " +
                                    "and the Vitrine agent is in \(Bundle.main.bundlePath)", installable: true)
            }
            return CameraStatus(ready: false, error: activate(), installable: false)
        }
        var unmanaged: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanaged)
        guard status == 0, let unmanaged else {
            return CameraStatus(ready: false, error: "the Vitrine Camera input can't be opened (CoreMediaIO error \(status))",
                                installable: false)
        }
        queue = unmanaged.takeRetainedValue()
        let started = CMIODeviceStartStream(device, stream)
        guard started == 0 else {
            queue = nil
            return CameraStatus(ready: false, error: "the Vitrine Camera input didn't start (CoreMediaIO error \(started))",
                                installable: false)
        }
        self.device = device
        self.stream = stream
        onLog?("camera on: \(request.width)x\(request.height) → \(Self.deviceName)")
        return CameraStatus(ready: true, device: Self.deviceName)
    }

    func frame(_ f: CameraFrame) {
        guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return } // full: drop
        guard let buffer = makeSampleBuffer(f) else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(buffer).toOpaque()) // the extension releases it
    }

    func stop() {
        guard queue != nil else { return }
        CMIODeviceStopStream(device, stream)
        queue = nil
        onLog?("camera off")
    }

    // MARK: Frames

    private func makeSampleBuffer(_ f: CameraFrame) -> CMSampleBuffer? {
        let w = Int(f.width), h = Int(f.height)
        guard w >= 2, w % 2 == 0, h >= 1, f.data.count == w * h * 2 else { return nil }
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8_yuvs,
                                        kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels) == kCVReturnSuccess, let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let stride = CVPixelBufferGetBytesPerRow(pixels), row = w * 2
            f.data.withUnsafeBytes { src in
                guard let s = src.baseAddress else { return }
                if w == Self.width, h == Self.height {
                    for y in 0..<h { memcpy(base + y * stride, s + y * row, row) }
                } else {
                    Self.fit(s, width: w, height: h, into: base, stride: stride)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &buffer)
        return buffer
    }

    /// Scales a packed YUYV frame to fit the advertised size, centred on black (VGA from a Mac
    /// camera without 720p, say). vImage has no packed 4:2:2 scaler, so each Y0 Cb Y1 Cr group is
    /// scaled as one four-channel pixel: chroma comes out right, and luma is resampled per column
    /// pair, which a webcam picture doesn't miss.
    private static func fit(_ src: UnsafeRawPointer, width w: Int, height h: Int, into dst: UnsafeMutableRawPointer, stride: Int) {
        let W = Self.width, H = Self.height
        var all = vImage_Buffer(data: dst, height: vImagePixelCount(H), width: vImagePixelCount(W / 2), rowBytes: stride)
        vImageBufferFill_ARGB8888(&all, [16, 128, 16, 128], vImage_Flags(kvImageNoFlags))  // black: Y 16, Cb Cr 128
        let scale = min(Double(W) / Double(w), Double(H) / Double(h))
        let dw = min(W, Int((Double(w) * scale / 2).rounded()) * 2), dh = min(H, Int((Double(h) * scale).rounded()))
        guard dw >= 2, dh >= 1 else { return }
        let x = (W - dw) / 4 * 2, y = (H - dh) / 2  // x stays on a pixel pair
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(h),
                                 width: vImagePixelCount(w / 2), rowBytes: w * 2)
        var to = vImage_Buffer(data: dst + y * stride + x * 2, height: vImagePixelCount(dh),
                               width: vImagePixelCount(dw / 2), rowBytes: stride)
        vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageNoFlags))
    }

    // MARK: Finding the device

    private static func findSink() -> (CMIOObjectID, CMIOStreamID)? {
        for device in objects(of: CMIOObjectID(kCMIOObjectSystemObject), CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        where name(of: device) == deviceName {
            let streams = objects(of: device, CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
            if let sink = streams.first(where: { name(of: $0) == sinkStreamName }) { return (device, sink) }
        }
        return nil
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objects(of owner: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(owner, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(owner, &addr, 0, nil, size, &used, &ids) == 0 else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func name(of object: CMIOObjectID) -> String? {
        var addr = address(CMIOObjectPropertySelector(kCMIOObjectPropertyName))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &name) == 0, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    // MARK: Activation

    /// Asks macOS to activate the extension (once per agent run) and says what's in the way.
    private func activate() -> String {
        switch activation {
        case .failed(let message):
            activation = .pending
            submitActivation()
            return message
        case .none:
            activation = .pending
            submitActivation()
            return "activating the Vitrine camera in the guest; try again in a moment"
        case .pending:
            return "activating the Vitrine camera in the guest; try again in a moment"
        case .needsApproval:
            return "allow the Vitrine camera in the guest's System Settings ▸ General ▸ Login Items & Extensions ▸ Camera Extensions, then try again"
        case .done:
            return "the Vitrine camera is active but doesn't show up yet; try again in a moment"
        }
    }

    private func submitActivation() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        activation = .needsApproval
        onLog?("camera extension waiting for approval in System Settings")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activation = .done
        onLog?("camera extension activated")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = "the Vitrine camera extension couldn't be activated: \(error.localizedDescription) " +
            "(it must be signed by an Apple Developer team; see docs/signing.md)"
        activation = .failed(message)
        onLog?(message)
    }
}
