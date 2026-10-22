// Dev helper: list a process's windows (number, layer, on-screen, bounds). Usage: swift list-windows.swift <pid>
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, "layer", w[kCGWindowLayer as String]!,
          "onscreen", w[kCGWindowIsOnscreen as String] ?? false,
          "alpha", w[kCGWindowAlpha as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
