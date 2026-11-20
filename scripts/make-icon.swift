// Generates a macOS iconset from the artwork used in the app.
// Usage: swift scripts/make-icon.swift [output-dir]
import Foundation
import ImageIO
import UniformTypeIdentifiers

let artwork = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Cleaner/Branding/AppIcon.png")
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)
let sizes = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

guard let source = CGImageSourceCreateWithURL(artwork as CFURL, nil) else {
    throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: artwork])
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for (name, pixels) in sizes {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels,
    ]
    let file = output.appendingPathComponent("icon_\(name).png")
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file])
    }
}

print(output.path)
