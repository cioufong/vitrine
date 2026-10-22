import AppKit
import ScreenCaptureKit
import CoreMedia
import VitrineAgentProtocol

/// Captures the guest display with ScreenCaptureKit and streams dirty rectangles to the host.
///
/// One display-wide stream (not one per window): the host crops each guest window out of the shared
/// framebuffer. Desktop wallpaper, Dock and shadows are excluded so window corners stay transparent.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Above this many queued bytes the streamer stops sending and accumulates damage instead.
    static let backpressureBytes = 48 << 20
    /// Largest single frame message; bigger regions are split into bands.
    static let maxChunkBytes = 8 << 20

    private let send: (AgentMessage) -> Bool
    private let pendingBytes: () -> Int
    private var stream: SCStream?
    /// Set by stop(); a start that is still awaiting ScreenCaptureKit checks it before publishing.
    private var cancelled = false
    private let queue = DispatchQueue(label: "vitrine.agent.capture", qos: .userInteractive)
    private var surfaceSize: (w: Int, h: Int) = (0, 0)
    private var needsFullFrame = true
    private var deferredDirty: CGRect = .null
    var log: (String) -> Void = { _ in }
    private(set) var framesSent = 0
    private(set) var bytesSent = 0

    init(send: @escaping (AgentMessage) -> Bool, pendingBytes: @escaping () -> Int) {
        self.send = send
        self.pendingBytes = pendingBytes
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start(maxFPS: Int) async throws {
        guard !cancelled, stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw AgentError("no display to capture") }
        let excludedBundles: Set<String> = ["com.apple.dock", "com.apple.wallpaper.agent", "com.apple.WindowManager",
                                            Bundle.main.bundleIdentifier ?? "io.github.cioufong.vitrine.agent"]
        let excludedApps = content.applications.filter {
            excludedBundles.contains($0.bundleIdentifier) || $0.processID == getpid()
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(maxFPS, 120))))
        config.queueDepth = 4
        config.backgroundColor = .clear
        config.ignoreShadowsDisplay = true
        config.colorSpaceName = CGColorSpace.sRGB
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if cancelled { try? await stream.stopCapture(); return }
        self.stream = stream
        queue.async { self.needsFullFrame = true }
        log("capture started \(config.width)x\(config.height) @\(maxFPS)fps")
    }

    func stop() async {
        cancelled = true
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    /// Forces the next frame to be sent in full (e.g. after the host reconnects).
    func invalidate() { queue.async { self.needsFullFrame = true } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription)")
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        if (w, h) != surfaceSize { surfaceSize = (w, h); needsFullFrame = true }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)

        var dirty = CGRect.null
        if needsFullFrame {
            dirty = bounds
        } else {
            let rects = (info[.dirtyRects] as? [NSDictionary] ?? []).compactMap { CGRect(dictionaryRepresentation: $0) }
            // dirtyRects are reported in points on scaled displays; normalise to pixels.
            let scale = (info[.scaleFactor] as? CGFloat) ?? 1
            for r in rects {
                let px = scale != 1 ? CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) : r
                dirty = dirty.union(px)
            }
        }
        dirty = dirty.union(deferredDirty).integral.intersection(bounds)
        guard !dirty.isNull, !dirty.isEmpty else { return }

        if pendingBytes() > Self.backpressureBytes {
            deferredDirty = dirty
            return
        }
        deferredDirty = .null
        needsFullFrame = false
        sendRegion(dirty, from: pixelBuffer, surfaceW: w, surfaceH: h)
    }

    private func sendRegion(_ r: CGRect, from pb: CVPixelBuffer, surfaceW: Int, surfaceH: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let x = Int(r.minX), width = Int(r.width)
        let rowBytes = width * 4
        let rowsPerChunk = max(1, Self.maxChunkBytes / rowBytes)
        var y = Int(r.minY)
        let maxY = Int(r.maxY)
        while y < maxY {
            let rows = min(rowsPerChunk, maxY - y)
            var data = Data(count: rows * rowBytes)
            data.withUnsafeMutableBytes { dst in
                let d = dst.baseAddress!
                for i in 0..<rows {
                    memcpy(d + i * rowBytes, base + (y + i) * stride + x * 4, rowBytes)
                }
            }
            let update = FrameUpdate(surfaceWidth: UInt32(surfaceW), surfaceHeight: UInt32(surfaceH),
                                     x: UInt32(x), y: UInt32(y), width: UInt32(width), height: UInt32(rows), data: data)
            if !send(.frame(update)) { return }
            bytesSent += data.count
            y += rows
        }
        framesSent += 1
    }
}
