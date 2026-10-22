import AppKit

/// Two-way clipboard sync used by both host and guest: watches the local general pasteboard and
/// applies remote content, suppressing echoes via content fingerprints.
public final class PasteboardSync {
    /// UTIs synchronized, in preference order. Files are not synced (use shared folders).
    public static let syncedTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .html, .png, .tiff, .URL,
    ]
    public static let maxBytes = 32 << 20

    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var lastFingerprint: Int?
    private var timer: Timer?
    public var onLocalChange: ((ClipboardContent) -> Void)?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.3) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() { timer?.invalidate(); timer = nil }

    /// Reads the current pasteboard contents.
    public func snapshot() -> ClipboardContent? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        var items: [ClipboardContent.Item] = []
        var total = 0
        for type in Self.syncedTypes where item.types.contains(type) {
            guard let data = item.data(forType: type) else { continue }
            total += data.count
            if total > Self.maxBytes { break }
            items.append(.init(type: type.rawValue, data: data))
        }
        return items.isEmpty ? nil : ClipboardContent(items: items)
    }

    func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let content = snapshot() else { return }
        let fp = content.fingerprint
        guard fp != lastFingerprint else { return }
        lastFingerprint = fp
        onLocalChange?(content)
    }

    /// Writes content that arrived from the other side.
    public func apply(_ content: ClipboardContent) {
        let fp = content.fingerprint
        guard fp != lastFingerprint else { return }
        lastFingerprint = fp
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for entry in content.items where Self.syncedTypes.map(\.rawValue).contains(entry.type) {
            item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
        }
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
    }
}
