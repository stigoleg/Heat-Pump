import CoreGraphics
import Foundation

// Usage: window-id <pid> [smallest|panel]
//        window-id --screen
// Prints the CoreGraphics window number of the largest (or smallest) normal window owned by
// the process, for `screencapture -l`; `panel` picks the largest window above the normal layer
// (the menu bar item's panel). With --screen it prints the main display's frame in
// points as "x y width height", the format AppKit's window frame strings end with.
let args = CommandLine.arguments
if args.count > 1, args[1] == "--screen" {
    let b = CGDisplayBounds(CGMainDisplayID())
    print("\(Int(b.origin.x)) \(Int(b.origin.y)) \(Int(b.width)) \(Int(b.height))")
    exit(0)
}
guard args.count > 1, let pid = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: window-id <pid> [smallest|panel] | --screen\n".utf8))
    exit(2)
}
let panel = args.count > 2 && args[2] == "panel"
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = info.filter {
    let layer = $0[kCGWindowLayer as String] as? Int ?? 0
    return ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (panel ? layer > 0 : layer == 0)
}
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
let sorted = windows.sorted { area($0) < area($1) }
let pick = args.count > 2 && args[2] == "smallest" ? sorted.first : sorted.last
guard let id = pick?[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
