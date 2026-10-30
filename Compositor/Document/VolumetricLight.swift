import CoreGraphics
import Foundation
import CoreImage

/// Filter › Volumetric Light: a light placed on the image, its beams through the air, and the haze it lights. `center`
/// is where the light is, in document coordinates, set by clicking the canvas; the filter opens with it on the layer's
/// brightest spot. The rest are 0–100: how bright the beams are, how far from the light they reach, how thick the
/// haze is, how big the light is, and how much the beams break up into shafts.
nonisolated struct VolumetricLightSettings: Equatable, Sendable {
    var center: CGPoint?
    var color = AdjustmentColor(red: 1, green: 0.86, blue: 0.68)
    var intensity: Double = 30
    var length: Double = 30
    var haze: Double = 60
    var size: Double = 20
    var shafts: Double = 0

    var isIdentity: Bool { intensity == 0 && haze == 0 }

    var normalized: Self {
        var result = self
        result.color = color.clamped
        result.intensity = ImageAdjustmentPixels.clamp(intensity, 0...100, 30)
        result.length = ImageAdjustmentPixels.clamp(length, 0...100, 30)
        result.haze = ImageAdjustmentPixels.clamp(haze, 0...100, 60)
        result.size = ImageAdjustmentPixels.clamp(size, 0...100, 20)
        result.shafts = ImageAdjustmentPixels.clamp(shafts, 0...100, 0)
        if let center, !(center.x.isFinite && center.y.isFinite) { result.center = nil }
        return result
    }
}

/// Volumetric Light worked out the way games draw light shafts after the fact: what gives off light is the light itself
/// and the photo's bright openings near it, with the subject (Vision's mask, as Rim Light finds it) and the photo's dark
/// shapes blocking it; each pixel then gathers that light along the line back toward the light, so whatever blocks it
/// casts shafts of shadow through the beams. The haze is thickest near the light and thinner in front of the subject,
/// which stands nearer than what's behind it, so the subject sits in the air rather than under a veil.
nonisolated enum VolumetricLighting {
    /// How bright the beams are at Intensity 100, over the photo.
    static let fullIntensity: Double = 5
    /// How thick the haze is at Haze 100.
    static let fullHaze: Double = 1

    /// `image` (the pixels of `source`) with the light at `light`, in `image`'s own coordinates (Core Image's, y up).
    static func apply(to image: CIImage, source: CGImage, settings: VolumetricLightSettings, light: CGPoint) throws -> CIImage {
        let settings = settings.normalized
        guard !settings.isIdentity else { return image }
        let extent = image.extent
        let side = max(extent.width, extent.height)
        let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
        let toImage = CGAffineTransform(scaleX: extent.width / CGFloat(source.width), y: extent.height / CGFloat(source.height))
        // With no subject found, nothing stands in front of the light.
        let subject = Self.subject(source).map { CIImage(cgImage: $0, options: raw).transformed(by: toImage).cropped(to: extent) }
            ?? CIImage.black.cropped(to: extent)
        // The beams are soft, so they're worked out at half size, which also halves the distance each one gathers over.
        let half = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let halfExtent = extent.applying(half).integral
        let small = image.samplingLinear().transformed(by: half).cropped(to: halfExtent)
        let smallSubject = subject.samplingLinear().transformed(by: half).cropped(to: halfExtent)
        // The photo's brightest, lightly blurred so one hot pixel doesn't set it, to tell its openings by.
        let peak = image.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: extent)
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        let beams = try MetalVolumetricLight.beams(small, subject: smallSubject, peak: peak, light: light.applying(half),
                                                   side: side / 2, settings: settings)
        let full = beams.clampedToExtent().applyingGaussianBlur(sigma: 1).samplingLinear()
            .transformed(by: half.inverted()).cropped(to: extent)
        // How near the subject a pixel is, for the haze and beams in front of it.
        let near = subject.clampedToExtent().applyingGaussianBlur(sigma: max(1, side * 0.003)).cropped(to: extent)
        // The photo's own lights, what's well brighter than the rest (headlights, windows, signs), each glowing into the
        // haze in its own color: a halo and a wider bloom.
        let lights = image.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
            .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 100, y: 100, z: 100, w: 1)])
        func blurred(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        let glows = blurred(lights, side * 0.012).applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: blurred(lights, side * 0.05).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0)])])
        // The air lit by the scene itself: its light spread wide, which the haze takes its color and brightness from.
        let ambient = blurred(image, side * 0.12)
        return try MetalVolumetricLight.combined(image, beams: full, near: near, glows: glows, ambient: ambient, light: light, side: side,
                                                 settings: settings).cropped(to: extent)
    }

    /// The subject in `image`, as Rim Light finds it, or nil when there's none; that's remembered too, so a photo without
    /// one isn't searched again at every slider step.
    static func subject(_ image: CGImage) -> CGImage? {
        if noSubject.contains(image) { return nil }
        do { return try RimLighting.subject(image) } catch {
            noSubject.remember(image)
            return nil
        }
    }
    /// Whether the subject in `image` has been looked for already, so lighting it is quick.
    static func hasLooked(for image: CGImage) -> Bool { noSubject.contains(image) || RimLighting.hasSubject(for: image) }
    private static let noSubject = Remembered()
    private final class Remembered: @unchecked Sendable {
        private let lock = NSLock()
        private var key: ObjectIdentifier?
        func contains(_ image: CGImage) -> Bool { lock.lock(); defer { lock.unlock() }; return key == ObjectIdentifier(image) }
        func remember(_ image: CGImage) { lock.lock(); key = ObjectIdentifier(image); lock.unlock() }
    }

    /// Where the light starts: in the biggest bright area of `image` (a window, the sky, a beam), at its brightest, in its
    /// pixels (rows top-down). Areas are the connected parts of a small copy near its top brightness, each weighed by its
    /// size and how bright it is, so a wide opening wins over a smaller patch of light on the rocks, even a hotter one.
    static func brightestPoint(in image: CGImage) -> CGPoint {
        let side = 64
        let width = max(1, image.width >= image.height ? side : side * image.width / max(1, image.height))
        let height = max(1, image.height >= image.width ? side : side * image.height / max(1, image.width))
        let center = CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2)
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false), let data = context.data else { return center }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        let pixels = data.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
        var gray = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels + y * stride + x * 4
                gray[y * width + x] = 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])
            }
        }
        // Lightly smoothed, so a speck doesn't count as an area.
        var bright = gray
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0, count = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let sx = x + dx, sy = y + dy
                        guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                        sum += gray[sy * width + sx]; count += 1
                    }
                }
                bright[y * width + x] = sum / count
            }
        }
        guard let peak = bright.max(), peak > 0 else { return center }
        let threshold = peak * 0.75
        var area = [Int](repeating: -1, count: width * height)
        var best = (score: -1.0, at: 0)
        for start in bright.indices where bright[start] >= threshold && area[start] < 0 {
            // One bright area, flooded from here.
            var stack = [start], score = 0.0, brightest = start
            area[start] = start
            while let index = stack.popLast() {
                score += bright[index]
                if bright[index] > bright[brightest] { brightest = index }
                let x = index % width, y = index / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let next = ny * width + nx
                    if area[next] < 0, bright[next] >= threshold { area[next] = start; stack.append(next) }
                }
            }
            if score > best.score { best = (score, brightest) }
        }
        return CGPoint(x: (Double(best.at % width) + 0.5) * Double(image.width) / Double(width),
                       y: (Double(best.at / width) + 0.5) * Double(image.height) / Double(height))
    }
}
