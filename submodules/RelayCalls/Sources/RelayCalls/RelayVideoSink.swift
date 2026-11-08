import CoreGraphics
import CoreVideo
import Foundation
import LiveKit

/// I420 planes of a decoded frame (software decoders, e.g. VP8). The planes stay valid while this object lives.
public final class RelayI420Buffer: @unchecked Sendable {
    private let buffer: I420VideoBuffer

    init(_ buffer: I420VideoBuffer) {
        self.buffer = buffer
    }

    public var width: Int { Int(self.buffer.width) }
    public var height: Int { Int(self.buffer.height) }
    public var chromaWidth: Int { Int(self.buffer.chromaWidth) }
    public var chromaHeight: Int { Int(self.buffer.chromaHeight) }
    public var strideY: Int { Int(self.buffer.strideY) }
    public var strideU: Int { Int(self.buffer.strideU) }
    public var strideV: Int { Int(self.buffer.strideV) }

    /// Calls `body` with the plane pointers (Y, U, V); they must not escape it.
    public func withPlanes<Result>(_ body: (_ y: UnsafePointer<UInt8>, _ u: UnsafePointer<UInt8>, _ v: UnsafePointer<UInt8>) throws -> Result) rethrows -> Result {
        return try self.buffer.withUnsafePlanes { planes in
            try body(planes.dataY, planes.dataU, planes.dataV)
        }
    }

    /// Copies of the planes (`stride × rows` bytes each), for consumers that keep `Data`.
    public var y: Data {
        return self.withPlanes { y, _, _ in Data(bytes: y, count: self.strideY * self.height) }
    }

    public var u: Data {
        return self.withPlanes { _, u, _ in Data(bytes: u, count: self.strideU * self.chromaHeight) }
    }

    public var v: Data {
        return self.withPlanes { _, _, v in Data(bytes: v, count: self.strideV * self.chromaHeight) }
    }
}

/// A decoded frame as `RelayVideoSink` delivers it, without conversion: a `CVPixelBuffer` (hardware H.264 decoding,
/// local camera frames; usually NV12) or I420 planes.
public struct RelayVideoFrame: @unchecked Sendable {
    public enum Buffer {
        case pixelBuffer(CVPixelBuffer)
        case i420(RelayI420Buffer)
    }

    public let buffer: Buffer
    /// Before rotation.
    public let width: Int
    public let height: Int
    public let rotation: RelayVideoRotation
    public let timestampNs: Int64
}

/// A LiveKit `VideoRenderer` that hands every frame of a track to a callback (on WebRTC's decoding thread), for the
/// platforms' own renderers (Telegram's `VideoFrameData`/`VideoSource`).
///
/// For adaptive stream, the subscriber reports what it shows: `viewSize` (points × scale is fine) and `isVisible`.
/// A hidden sink lets LiveKit pause the track.
public final class RelayVideoSink: NSObject, VideoRenderer, @unchecked Sendable {
    private let onFrame: (RelayVideoFrame) -> Void
    @MainActor public var isVisible: Bool = true
    @MainActor public var viewSize: CGSize = CGSize(width: 640, height: 360)

    /// `onFrame` runs on WebRTC's thread for every frame; keep it short.
    public init(onFrame: @escaping (RelayVideoFrame) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    @MainActor public var isAdaptiveStreamEnabled: Bool {
        return self.isVisible
    }

    @MainActor public var adaptiveStreamSize: CGSize {
        return self.isVisible ? self.viewSize : .zero
    }

    public func render(frame: VideoFrame) {
        guard let converted = Self.convert(frame) else {
            return
        }
        self.onFrame(converted)
    }

    static func convert(_ frame: VideoFrame) -> RelayVideoFrame? {
        let buffer: RelayVideoFrame.Buffer
        if let pixel = frame.buffer as? CVPixelVideoBuffer {
            buffer = .pixelBuffer(pixel.pixelBuffer)
        } else if let i420 = frame.buffer as? I420VideoBuffer {
            buffer = .i420(RelayI420Buffer(i420))
        } else {
            return nil
        }
        return RelayVideoFrame(buffer: buffer, width: Int(frame.dimensions.width), height: Int(frame.dimensions.height), rotation: RelayVideoRotation(frame.rotation), timestampNs: frame.timeStampNs)
    }
}
