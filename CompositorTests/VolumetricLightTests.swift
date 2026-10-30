import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// Filter › Volumetric Light, on a dark room with a bright window crossed by a bar.
struct VolumetricLightTests {
    private let width = 600, height = 400

    /// The window's top-left corner and size, rows top-down, and the bar down its middle.
    private let window = CGRect(x: 260, y: 40, width: 80, height: 80)

    private func room() throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // These contexts draw rows top-down, as the image's.
        context.setFillColor(CGColor(red: 1, green: 0.97, blue: 0.9, alpha: 1))
        context.fill(window)
        context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        context.fill(CGRect(x: window.midX - 4, y: window.minY, width: 8, height: window.height))
        return try #require(context.makeImage())
    }

    /// Brightness at a pixel, rows top-down.
    private func gray(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let at = y * context.bytesPerRow + x * 4
        return (Int(bytes[at]) + Int(bytes[at + 1]) + Int(bytes[at + 2])) / 3
    }

    @Test func theLightStartsOnTheBrightestSpot() throws {
        let point = VolumetricLighting.brightestPoint(in: try room())
        #expect(window.insetBy(dx: -10, dy: -10).contains(point), "on the window: \(point)")
    }

    /// A wide opening wins over a smaller, hotter patch of light: the biggest bright area, not the brightest pixel.
    @Test func theLightStartsInTheBiggestBrightArea() throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A wide opening at the top, a little less bright, and a small hot patch near the foot.
        context.setFillColor(CGColor(red: 0.9, green: 0.88, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 220, y: 20, width: 160, height: 120))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 330, width: 30, height: 30))
        let point = VolumetricLighting.brightestPoint(in: try #require(context.makeImage()))
        #expect(CGRect(x: 220, y: 20, width: 160, height: 120).contains(point), "in the opening: \(point)")
    }

    @Test func beamsLightTheRoomAndTheBarCastsAShaftOfShadow() throws {
        let original = try room()
        var settings = FilterSettings()
        settings.volumetric.center = CGPoint(x: window.midX, y: window.midY)
        settings.volumetric.haze = 0
        settings.volumetric.shafts = 0
        settings.volumetric.length = 100
        settings.volumetric.intensity = 80
        let lit = try PixelFilter.run(FilterJob(kind: .volumetricLight, image: original, settings: settings, scale: 1, selection: nil,
                                                mapping: .identity))
        // Below the window, straight down from it: behind the bar, and to one side where its light comes through.
        let below = Int(window.maxY) + 60
        let shadowed = try gray(lit, Int(window.midX), below), open = try gray(lit, Int(window.minX) + 18, below)
        let before = try gray(original, Int(window.minX) + 18, below)
        #expect(open > before + 20, "the beams light the room below the window: \(before) → \(open)")
        #expect(shadowed < open - 6, "the bar's shadow runs through them: \(shadowed) against \(open)")
        let corner = try gray(lit, 5, height - 5)
        #expect(corner < open - 10, "the far corner gets less than near the window: \(corner) against \(open)")
    }

    @Test func zeroIntensityAndHazeLeaveTheImage() throws {
        var settings = VolumetricLightSettings()
        settings.intensity = 0
        settings.haze = 0
        #expect(settings.isIdentity)
    }

    /// Renders the photos in `VOLUMETRIC_IMAGES` ("path,x,y" separated by ";", the light as fractions of the width and
    /// height from the top left) as attachments, to look at. Skipped when it's unset.
    @Test func renderSamples() throws {
        guard let list = ProcessInfo.processInfo.environment["VOLUMETRIC_IMAGES"] else { return }
        for (index, entry) in list.split(separator: ";").enumerated() {
            let parts = entry.split(separator: ",").map(String.init)
            guard parts.count >= 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: parts[0]) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let x = Double(parts[1]), let y = Double(parts[2]) else { continue }
            var settings = FilterSettings()
            settings.volumetric.center = CGPoint(x: x * Double(image.width), y: y * Double(image.height))
            let names = ["intensity", "length", "haze", "size", "shafts"]
            for (index, name) in names.enumerated() where parts.count > 3 + index {
                guard let value = Double(parts[3 + index]) else { continue }
                switch name {
                case "intensity": settings.volumetric.intensity = value
                case "length": settings.volumetric.length = value
                case "haze": settings.volumetric.haze = value
                case "size": settings.volumetric.size = value
                default: settings.volumetric.shafts = value
                }
            }
            if parts.count >= 11, let r = Double(parts[8]), let g = Double(parts[9]), let b = Double(parts[10]) {
                settings.volumetric.color = AdjustmentColor(red: r, green: g, blue: b)
            }
            let lit = try PixelFilter.run(FilterJob(kind: .volumetricLight, image: image, settings: settings, scale: 1, selection: nil,
                                                    mapping: .identity))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, lit, nil)
            CGImageDestinationFinalize(destination)
            Attachment.record(data as Data, named: "sample-\(index)-lit.png")
        }
    }
}
