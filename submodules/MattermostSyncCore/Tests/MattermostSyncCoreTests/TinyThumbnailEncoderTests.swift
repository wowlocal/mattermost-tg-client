import XCTest
import ImageIO
@testable import MattermostSyncCore

final class TinyThumbnailEncoderTests: XCTestCase {
    /// An RGBA image with smooth gradients and a hard edge (what a video's first frame looks like at 40 pixels).
    private func image(width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                rgba[index] = UInt8(x * 255 / max(1, width - 1))
                rgba[index + 1] = UInt8(y * 255 / max(1, height - 1))
                rgba[index + 2] = x < width / 2 ? 40 : 200
            }
        }
        return rgba
    }

    /// Decodes a JPEG with ImageIO into RGBA.
    private func decode(_ jpeg: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, rgba) : nil
    }

    private func meanError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0
        var count = 0
        for index in 0 ..< min(a.count, b.count) where index % 4 != 3 {
            sum += abs(Double(a[index]) - Double(b[index]))
            count += 1
        }
        return sum / Double(max(1, count))
    }

    func testDecodesAsTelegramRebuildsIt() throws {
        for (width, height) in [(40, 40), (40, 24), (17, 33), (8, 8), (1, 1)] {
            let original = image(width: width, height: height)
            let stripped = try XCTUnwrap(TinyThumbnailEncoder.encode(rgba: original, width: width, height: height))
            XCTAssertEqual(stripped[0], 1)
            XCTAssertEqual(Int(stripped[1]), height)
            XCTAssertEqual(Int(stripped[2]), width)
            let jpeg = try XCTUnwrap(TinyThumbnailEncoder.jpeg(fromStripped: stripped))
            let decoded = try XCTUnwrap(decode(jpeg), "\(width)×\(height) did not decode")
            XCTAssertEqual(decoded.width, width)
            XCTAssertEqual(decoded.height, height)
            // Quality 20: blurred, but the same picture. Tiny images have steep gradients (32 levels a pixel at 8 × 8)
            // that 4:2:0 chroma can't keep.
            let error = meanError(decoded.rgba, original)
            print("tiny thumbnail \(width)×\(height): \(stripped.count) bytes, mean error \(error)")
            XCTAssertLessThan(error, width * height >= 400 ? 10 : 24, "\(width)×\(height)")
        }
    }

    func testTypicalSizeFitsAMarker() throws {
        let stripped = try XCTUnwrap(TinyThumbnailEncoder.encode(rgba: image(width: 40, height: 40), width: 40, height: 40))
        XCTAssertLessThan(stripped.count, 1500)
    }

    func testFlatImageStaysFlat() throws {
        let gray = [UInt8](repeating: 128, count: 40 * 40 * 4)
        let stripped = try XCTUnwrap(TinyThumbnailEncoder.encode(rgba: gray, width: 40, height: 40))
        let decoded = try XCTUnwrap(decode(try XCTUnwrap(TinyThumbnailEncoder.jpeg(fromStripped: stripped))))
        XCTAssertLessThan(meanError(decoded.rgba, gray), 3)
    }

    func testRejectsBadInput() {
        XCTAssertNil(TinyThumbnailEncoder.encode(rgba: [], width: 0, height: 0))
        XCTAssertNil(TinyThumbnailEncoder.encode(rgba: [UInt8](repeating: 0, count: 256 * 4), width: 256, height: 1))
        XCTAssertNil(TinyThumbnailEncoder.encode(rgba: [UInt8](repeating: 0, count: 10), width: 4, height: 4))
        XCTAssertNil(TinyThumbnailEncoder.jpeg(fromStripped: Data([2, 1, 1])))
        XCTAssertNil(TinyThumbnailEncoder.jpeg(fromStripped: Data([1, 1])))
    }
}
