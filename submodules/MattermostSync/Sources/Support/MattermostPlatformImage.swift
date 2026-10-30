import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
import WebPBinding
#else
import AppKit
import libwebp
#endif

/// The few image types and operations MattermostSync draws with, on iOS (UIKit, the app's WebPBinding) and macOS
/// (AppKit, the macOS app's libwebp), so the drawing code is the same on both. On iOS they are UIKit's own calls.
#if os(iOS)
typealias MMImage = UIImage
typealias MMColor = UIColor
typealias MMFont = UIFont
#else
typealias MMImage = NSImage
typealias MMColor = NSColor
typealias MMFont = NSFont
#endif

enum MMImageRenderer {
    /// An image of `size` points at `scale` drawn by `draw` in a top-left-origin context (UIKit's coordinates on
    /// both platforms), with UIKit/AppKit drawing (`MMImage.mmDraw`, `NSAttributedString.draw`) going to it.
    static func image(size: CGSize, scale: CGFloat = 1.0, opaque: Bool, _ draw: (CGContext) -> Void) -> MMImage {
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext)
        }
        #else
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let bitmapInfo = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
            return NSImage(size: size)
        }
        context.translateBy(x: 0.0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else {
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }

    /// The context `draw` is drawing in (`UIGraphicsGetCurrentContext` on iOS).
    static func currentContext() -> CGContext? {
        #if os(iOS)
        return UIGraphicsGetCurrentContext()
        #else
        return NSGraphicsContext.current?.cgContext
        #endif
    }
}

extension MMImage {
    /// Draws the image into `rect` of the current context, upright in a top-left-origin context.
    func mmDraw(in rect: CGRect) {
        #if os(iOS)
        self.draw(in: rect)
        #else
        self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        #endif
    }

    var mmCGImage: CGImage? {
        #if os(iOS)
        return self.cgImage
        #else
        return self.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    func mmPNGData() -> Data? {
        #if os(iOS)
        return self.pngData()
        #else
        guard let cgImage = self.mmCGImage else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        #endif
    }

    func mmJPEGData(quality: CGFloat) -> Data? {
        #if os(iOS)
        return self.jpegData(compressionQuality: quality)
        #else
        guard let cgImage = self.mmCGImage else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    /// A WebP of the image; `quality` from 0 to 1.
    func mmWebPData(quality: CGFloat) -> Data? {
        #if os(iOS)
        return try? WebP.convert(toWebP: self, quality: quality)
        #else
        guard let cgImage = self.mmCGImage else {
            return nil
        }
        return convertToWebP(cgImage, quality * 100.0)
        #endif
    }
}
