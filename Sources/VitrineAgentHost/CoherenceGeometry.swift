import Foundation
import CoreGraphics
import VitrineAgentProtocol

/// Maps between guest global coordinates (points, top-left origin) and host screen coordinates
/// (AppKit points, bottom-left origin of the primary screen).
///
/// In Coherence the guest display is sized to the host screen, so the mapping is a vertical flip
/// plus the host screen's origin. Guest windows overlapping the guest menu bar are clamped below it.
public struct CoherenceGeometry: Equatable, Sendable {
    /// The host screen that hosts guest windows, in AppKit global coordinates.
    public var hostScreenFrame: CGRect
    public var display: DisplayInfo

    public init(hostScreenFrame: CGRect, display: DisplayInfo) {
        self.hostScreenFrame = hostScreenFrame
        self.display = display
    }

    private var scaleX: CGFloat { hostScreenFrame.width / CGFloat(display.widthPoints) }
    private var scaleY: CGFloat { hostScreenFrame.height / CGFloat(display.heightPoints) }

    /// Host window frame (AppKit) for a guest window frame.
    public func hostRect(forGuest r: Rect) -> CGRect {
        let w = CGFloat(r.width) * scaleX, h = CGFloat(r.height) * scaleY
        let x = hostScreenFrame.minX + CGFloat(r.x) * scaleX
        let y = hostScreenFrame.maxY - CGFloat(r.y) * scaleY - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Guest global point for a host global point (AppKit).
    public func guestPoint(forHost p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - hostScreenFrame.minX) / scaleX,
                y: (hostScreenFrame.maxY - p.y) / scaleY)
    }

    /// Guest frame for a host window frame (used when the user moves/resizes a Coherence window).
    public func guestRect(forHost r: CGRect) -> Rect {
        let topLeft = guestPoint(forHost: CGPoint(x: r.minX, y: r.maxY))
        return Rect(x: Double(topLeft.x), y: Double(topLeft.y),
                    width: Double(r.width / scaleX), height: Double(r.height / scaleY))
    }

    /// Normalized `contentsRect` selecting the guest window inside the full-display framebuffer.
    /// For IOSurface contents on an unflipped layer, the unit contents space starts at the surface's
    /// first row, i.e. the guest's top-left (verified on-screen with `--coherence-demo`).
    public func contentsRect(forGuest r: Rect) -> CGRect {
        let W = display.widthPoints, H = display.heightPoints
        return CGRect(x: r.x / W, y: r.y / H, width: r.width / W, height: r.height / H)
    }

    /// Guest pixel size that matches a host screen, for reconfiguring the guest display.
    public static func guestDisplayPixels(forHostScreen frame: CGRect, backingScale: CGFloat) -> (width: Int, height: Int) {
        (Int((frame.width * backingScale).rounded()), Int((frame.height * backingScale).rounded()))
    }
}
