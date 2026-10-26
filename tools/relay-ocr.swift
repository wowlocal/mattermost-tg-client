// Text on a simulator screenshot, with its position in screen points (Phase 4E).
//
//   relay-ocr <screenshot.png> <scale>
//
// Prints one JSON array: [{"text": "...", "x": .., "y": .., "w": .., "h": ..}], frames in points (pixels / scale),
// origin top left. tools/relay-axe.py compiles this once (`xcrun swiftc -O`) and uses it for what AXe's accessibility
// tree doesn't show: Telegram's alerts and action sheets, the tab bar, the chat list header.
import AppKit
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 3, let scale = Double(args[2]), let image = NSImage(contentsOfFile: args[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: relay-ocr <png> <scale>\n".data(using: .utf8)!)
    exit(2)
}
let width = Double(cgImage.width)
let height = Double(cgImage.height)

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])

var out: [[String: Any]] = []
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox  // normalized, origin bottom left
    out.append([
        "text": candidate.string,
        "x": box.minX * width / scale,
        "y": (1.0 - box.maxY) * height / scale,
        "w": box.width * width / scale,
        "h": box.height * height / scale,
    ])
}
let data = try JSONSerialization.data(withJSONObject: out, options: [])
FileHandle.standardOutput.write(data)
