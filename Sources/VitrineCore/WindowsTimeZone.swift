import Foundation

/// Maps the Mac's time zone to a Windows time zone ID ("Taipei Standard Time"), via the ICU that
/// ships with macOS (libicucore exports CLDR's windowsZones mapping as ucal_getWindowsTimeZoneID).
public enum WindowsTimeZone {
    private typealias GetWindowsID = @convention(c) (UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32,
                                                     UnsafeMutablePointer<Int32>) -> Int32

    private static let getWindowsID: GetWindowsID? = {
        guard let lib = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY),
              let sym = dlsym(lib, "ucal_getWindowsTimeZoneID") else { return nil }
        return unsafeBitCast(sym, to: GetWindowsID.self)
    }()

    /// Windows ID for an IANA zone, nil if ICU has no mapping (e.g. "UTC" maps to "UTC").
    public static func id(forIANA iana: String) -> String? {
        guard let fn = getWindowsID else { return nil }
        let input = Array(iana.utf16)
        var out = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let n = input.withUnsafeBufferPointer { i in
            fn(i.baseAddress!, Int32(i.count), &out, Int32(out.count), &status)
        }
        guard status <= 0, n > 0 else { return nil } // U_ZERO_ERROR or warnings
        return String(utf16CodeUnits: out, count: Int(n))
    }

    /// The Mac's current zone as a Windows ID ("UTC" if it can't be mapped).
    public static var current: String { id(forIANA: TimeZone.current.identifier) ?? "UTC" }
}
