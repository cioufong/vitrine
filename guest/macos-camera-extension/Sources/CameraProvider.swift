import CoreMediaIO
import CoreVideo
import Foundation

/// Names shared with the agent (guest/macos-agent/Sources/CameraSink.swift).
enum VitrineCamera {
    static let deviceName = "Vitrine Camera"
    static let sinkStreamName = "Vitrine Camera Input"
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let fps: Int32 = 30
    // Fixed so apps remember the camera across restarts.
    static let deviceID = UUID(uuidString: "5C1D7E2A-3B5E-4F0A-9C58-7E1D6A3F2B40")!
    static let sourceID = UUID(uuidString: "5C1D7E2A-3B5E-4F0A-9C58-7E1D6A3F2B41")!
    static let sinkID = UUID(uuidString: "5C1D7E2A-3B5E-4F0A-9C58-7E1D6A3F2B42")!
}

final class CameraProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var device: CameraDevice!

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        device = CameraDevice()
        do { try provider.addDevice(device.device) } catch { fatalError("addDevice: \(error)") }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Vitrine" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStream!
    private var sink: SinkStream!

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: VitrineCamera.deviceName, deviceID: VitrineCamera.deviceID,
                                     legacyDeviceID: VitrineCamera.deviceID.uuidString, source: self)
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_422YpCbCr8_yuvs,
                                       width: VitrineCamera.width, height: VitrineCamera.height, extensions: nil,
                                       formatDescriptionOut: &description)
        let frame = CMTime(value: 1, timescale: VitrineCamera.fps)
        let format = CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: frame,
                                               minFrameDuration: frame, validFrameDurations: nil)
        source = SourceStream(name: VitrineCamera.deviceName, id: VitrineCamera.sourceID, format: format)
        sink = SinkStream(name: VitrineCamera.sinkStreamName, id: VitrineCamera.sinkID, format: format) { [weak self] buffer in
            self?.source.send(buffer)
        }
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("addStream: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = 0x7669_7274 } // 'virt' (kIOAudioDeviceTransportTypeVirtual)
        if properties.contains(.deviceModel) { p.model = "Vitrine Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

/// What apps read.
final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let lock = NSLock()
    /// Streams started and not yet stopped: each app reading the camera starts and stops its own,
    /// and frames flow while any is running.
    private var started = 0

    init(name: String, id: UUID, format: CMIOExtensionStreamFormat) {
        self.format = format
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: .source, clockType: .hostTime, source: self)
    }

    func send(_ buffer: CMSampleBuffer) {
        guard lock.withLock({ started > 0 }) else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: now)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VitrineCamera.fps) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { lock.withLock { started += 1 } }
    func stopStream() throws { lock.withLock { started = max(0, started - 1) } }
}

/// What the agent writes: each buffer it enqueues is handed on to the source stream.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let forward: (CMSampleBuffer) -> Void
    private let lock = NSLock()
    private var client: CMIOExtensionClient?
    private var running = false

    init(name: String, id: UUID, format: CMIOExtensionStreamFormat, forward: @escaping (CMSampleBuffer) -> Void) {
        self.format = format
        self.forward = forward
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VitrineCamera.fps) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 4 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        lock.withLock { self.client = client }
        return true
    }

    func startStream() throws {
        guard let client = lock.withLock({ () -> CMIOExtensionClient? in running = true; return self.client }) else { return }
        consume(from: client)
    }

    func stopStream() throws { lock.withLock { running = false } }

    private func consume(from client: CMIOExtensionClient) {
        stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, error in
            guard let self, self.lock.withLock({ self.running }) else { return }
            if let buffer {
                self.forward(buffer)
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
            }
            if error != nil {
                // The agent went away or has nothing queued: ask again shortly rather than spin.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { self.consume(from: client) }
            } else {
                self.consume(from: client)
            }
        }
    }
}
