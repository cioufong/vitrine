import AppKit
import QuartzCore

/// Diagnostics: describes a view's layer tree (classes, sizes, contents types). Used to study how
/// VZVirtualMachineView presents guest frames. Enable with VITRINE_DEBUG_LAYERS=1.
public enum LayerInspector {
    public static func describe(view: NSView) -> String {
        var out = "view \(type(of: view)) frame=\(view.frame)\n"
        for sub in view.subviews { out += "  subview \(type(of: sub)) frame=\(sub.frame)\n" }
        if let layer = view.layer { describe(layer, depth: 0, into: &out) }
        for sub in view.subviews {
            if let l = sub.layer { out += "-- subview \(type(of: sub)) layers:\n"; describe(l, depth: 1, into: &out) }
        }
        return out
    }

    static func describe(_ layer: CALayer, depth: Int, into out: inout String) {
        guard depth < 12 else { return }
        let pad = String(repeating: "  ", count: depth)
        var contents = "nil"
        if let c = layer.contents {
            let cf = c as CFTypeRef
            let typeID = CFGetTypeID(cf)
            if typeID == IOSurfaceGetTypeID() {
                let s = unsafeBitCast(cf, to: IOSurfaceRef.self)
                contents = "IOSurface \(IOSurfaceGetWidth(s))x\(IOSurfaceGetHeight(s)) fmt=\(String(format: "%08x", IOSurfaceGetPixelFormat(s))) id=\(IOSurfaceGetID(s))"
            } else if typeID == CGImage.typeID {
                contents = "CGImage"
            } else {
                contents = String(describing: type(of: c))
            }
        }
        out += "\(pad)\(type(of: layer)) bounds=\(layer.bounds.size) contents=\(contents)\n"
        for s in layer.sublayers ?? [] { describe(s, depth: depth + 1, into: &out) }
    }
}
