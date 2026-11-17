import CoreGraphics
import Foundation
import ImageIO
import IOSurface

/// Turns a VM's framebuffer, an IOSurface of 8-bit BGRA pixels, into an image and a PNG file.
public enum FrameImage {
    private static let bgra: OSType = 0x4247_5241  // 'BGRA'

    /// Copies the surface's pixels into an image that no longer depends on the surface. The alpha
    /// byte is ignored: a framebuffer is opaque.
    public static func image(from surface: IOSurfaceRef) throws -> CGImage {
        let format = IOSurfaceGetPixelFormat(surface)
        guard format == bgra else {
            let fourCC = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((format >> $0) & 0xff))) }
            throw PaddockError("the VM's framebuffer is in pixel format '\(String(fourCC))', not BGRA")
        }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let pixels = Data(bytes: IOSurfaceGetBaseAddress(surface), count: bytesPerRow * height)
        let space = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace)
            .flatMap { CGColorSpace(propertyListPlist: $0) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PaddockError("can't make an image of the VM's \(width)x\(height) framebuffer")
        }
        return image
    }

    /// Writes `image` to `url` as a PNG, replacing any file there.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw PaddockError("can't write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PaddockError("can't write \(url.path)")
        }
    }
}
