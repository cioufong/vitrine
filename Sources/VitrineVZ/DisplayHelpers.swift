import AppKit

public enum CoherenceDisplay {
    /// Guest display size that matches `screen` 1:1 (full frame, Retina pixels) and its PPI.
    public static func pixels(for screen: NSScreen) -> (width: Int, height: Int, ppi: Int) {
        let scale = screen.backingScaleFactor
        let w = Int((screen.frame.width * scale).rounded())
        let h = Int((screen.frame.height * scale).rounded())
        var ppi = scale >= 2 ? 220 : 110
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let mm = CGDisplayScreenSize(CGDirectDisplayID(num.uint32Value))
            if mm.width > 0 { ppi = Int((Double(w) / (mm.width / 25.4)).rounded()) }
        }
        return (w, h, min(max(ppi, 80), 300))
    }
}
