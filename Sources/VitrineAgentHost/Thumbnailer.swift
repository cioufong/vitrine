import AppKit
import CoreImage
import QuartzCore

/// Makes Control Center thumbnails from whatever IOSurface a display view is presenting
/// (VZVirtualMachineView's framebuffer layer, or Vitrine's own QEMU/Coherence layers).
/// Reads layer contents only — no private API calls — and returns nil if nothing is found.
public enum Thumbnailer {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    public static func surface(in view: NSView) -> IOSurface? {
        func find(_ layer: CALayer) -> IOSurface? {
            if let c = layer.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                return unsafeBitCast(c as CFTypeRef, to: IOSurface.self)
            }
            for s in layer.sublayers ?? [] { if let f = find(s) { return f } }
            return nil
        }
        if let l = view.layer, let s = find(l) { return s }
        for sub in view.subviews { if let s = surface(in: sub) { return s } }
        return nil
    }

    /// PNG of the surface scaled to `maxWidth` pixels.
    public static func png(from surface: IOSurface, maxWidth: CGFloat = 480) -> Data? {
        let image = CIImage(ioSurface: surface)
        guard image.extent.width > 0 else { return nil }
        let scale = min(1, maxWidth / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    /// Mean red, green, blue (0–255) of the pixels in `rect` of `image`, with `rect` in guest display
    /// coordinates (origin top left), clipped to the image; nil when nothing of it is inside.
    public static func meanColor(of image: CIImage, in rect: CGRect) -> [Double]? {
        let e = image.extent
        let flipped = CGRect(x: e.minX + rect.minX, y: e.maxY - rect.maxY, width: rect.width, height: rect.height).intersection(e)
        guard !flipped.isNull, flipped.width >= 1, flipped.height >= 1,
              let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: flipped)])?.outputImage
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel.prefix(3).map(Double.init)
    }

    /// Captures the view's current frame into `url` (atomic write). Returns true on success.
    @discardableResult
    public static func save(from view: NSView, to url: URL) -> Bool {
        guard let s = surface(in: view), let data = png(from: s) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
