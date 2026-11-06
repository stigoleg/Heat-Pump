import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Usage: image-diff <a.png> <b.png> [diff.png]
// Prints the share of pixels that differ (any channel by more than 24 of 255) as a percentage,
// or "size" when the images differ in size. With a third path it writes image b dimmed, with
// the differing pixels in red, so the changes are easy to find.
func load(_ path: String) -> (pixels: [UInt8], width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}

let args = CommandLine.arguments
guard args.count >= 3, let a = load(args[1]), let b = load(args[2]) else {
    FileHandle.standardError.write(Data("usage: image-diff <a.png> <b.png> [diff.png]\n".utf8))
    exit(2)
}
guard a.width == b.width, a.height == b.height else {
    print("size")
    exit(1)
}
var out = b.pixels
var differing = 0
for i in stride(from: 0, to: a.pixels.count, by: 4) {
    let changed = (0..<3).contains { abs(Int(a.pixels[i + $0]) - Int(b.pixels[i + $0])) > 24 }
    if changed {
        differing += 1
        out[i] = 255; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 255
    } else {
        for c in 0..<3 { out[i + c] = UInt8(155 + Int(out[i + c]) * 100 / 255) }
    }
}
print(String(format: "%.2f", Double(differing) / Double(a.width * a.height) * 100))
if args.count > 3 {
    let context = CGContext(
        data: &out, width: b.width, height: b.height, bitsPerComponent: 8, bytesPerRow: b.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    if let image = context?.makeImage(),
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)
    {
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
