import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import Testing
@testable import PaddockCore

@Suite struct FrameImageTests {
    /// A 4x2 surface in `format` with one pixel set: x 1, y 0, B 0x11, G 0x22, R 0x33.
    func surface(format: OSType = 0x4247_5241) throws -> IOSurfaceRef {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: 4, kIOSurfaceHeight: 2, kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: format,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        IOSurfaceLock(surface, [], nil)
        let pixel = IOSurfaceGetBaseAddress(surface).advanced(by: 4).assumingMemoryBound(to: UInt8.self)
        pixel[0] = 0x11
        pixel[1] = 0x22
        pixel[2] = 0x33
        pixel[3] = 0  // a framebuffer's alpha byte means nothing
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }

    @Test func copiesBGRAPixelsIntoAnOpaqueImage() throws {
        let image = try FrameImage.image(from: surface())
        #expect(image.width == 4 && image.height == 2)

        var rgba = [UInt8](repeating: 0, count: 4 * 2 * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                .map { $0.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 2)); return true } ?? false
        }
        #expect(drawn)
        // Row 0 in memory is the image's top row.
        #expect(Array(rgba[4..<8]) == [0x33, 0x22, 0x11, 0xff])
    }

    @Test func refusesOtherPixelFormats() throws {
        #expect(throws: PaddockError.self) { try FrameImage.image(from: surface(format: 0x5247_4241)) }  // 'RGBA'
    }

    @Test func encodesAPNG() throws {
        let png = try FrameImage.pngData(FrameImage.image(from: surface()))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let read = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(read.width == 4 && read.height == 2)
    }
}
