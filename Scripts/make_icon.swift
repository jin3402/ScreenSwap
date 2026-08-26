#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns from Resources/AppIcon-source.png.
//
//   swift Scripts/make_icon.swift
//
// The source is a single square PNG with the icon's rounded-corner plate
// already drawn and transparent everywhere else — this script only resamples
// it into every size .icns needs and packages them with iconutil. It does not
// draw anything itself, so replacing Resources/AppIcon-source.png with
// different artwork (same square, transparent-background convention) is all
// a redesign takes.
//
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourcePath = root.appendingPathComponent("Resources/AppIcon-source.png")

guard let master = NSImage(contentsOfFile: sourcePath.path),
      let masterCG = master.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Resources/AppIcon-source.png not found or unreadable\n".data(using: .utf8)!)
    exit(1)
}
guard masterCG.width == masterCG.height else {
    FileHandle.standardError.write("AppIcon-source.png must be square (got \(masterCG.width)x\(masterCG.height))\n".data(using: .utf8)!)
    exit(1)
}

func render(pixels: Int) -> Data? {
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(masterCG, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),       ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),       ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let data = render(pixels: variant.pixels) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }

try? FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
