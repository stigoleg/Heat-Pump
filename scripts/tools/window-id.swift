import CoreGraphics
import Foundation

// Usage: window-id <pid> [smallest|panel]
//        window-id --screen [retina]
//        window-id --status-items
// Prints the CoreGraphics window number of the largest (or smallest) normal window owned by
// the process, for `screencapture -l`; `panel` picks the largest window above the normal layer
// (the menu bar item's panel). With --screen it prints the main display's frame in points as
// "x y width height", the format AppKit's window frame strings end with. With --status-items it
// prints "id x y width height" per menu bar item on screen: since macOS 26 Control Center owns
// those windows, so a script finds the app's item as the one that appeared after launch.
let args = CommandLine.arguments
if args.count > 1, args[1] == "--screen" {
    // `retina`: the first 2x display (a laptop's own screen next to a 1x monitor), in AppKit
    // coordinates (origin at the bottom left of the main display); else the main display.
    var display = CGMainDisplayID()
    if args.count > 2, args[2] == "retina" {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        if let found = ids.prefix(Int(count)).first(where: { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
            return mode.pixelWidth >= 2 * mode.width
        }) {
            display = found
        }
    }
    let b = CGDisplayBounds(display)
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    print("\(Int(b.origin.x)) \(Int(mainHeight - b.origin.y - b.height)) \(Int(b.width)) \(Int(b.height))")
    exit(0)
}
if args.count > 1, args[1] == "--status-items" {
    let level = Int(CGWindowLevelForKey(.statusWindow))
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for item in all where (item[kCGWindowLayer as String] as? Int) == level {
        guard let id = item[kCGWindowNumber as String] as? Int, let b = item[kCGWindowBounds as String] as? [String: Double] else { continue }
        print("\(id) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0))")
    }
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
