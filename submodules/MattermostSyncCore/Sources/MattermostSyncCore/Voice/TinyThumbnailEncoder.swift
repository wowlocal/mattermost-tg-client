import Foundation

/// Telegram's "stripped" thumbnails (`immediateThumbnailData`, decoded by TinyThumbnail's `decodeTinyThumbnail`): a
/// tiny baseline JPEG whose headers are left out because every such JPEG has the same ones. The decoder puts the
/// fixed header (quantization tables of libjpeg quality 20, the standard Huffman tables, 4:2:0 sampling) in front of
/// the entropy-coded data, writes the size into it and adds the end marker. Telegram's server makes these; Relay makes
/// its own for video messages (5B), so a round video shows a blurred first frame before its file is downloaded.
///
/// Format: `[0x01, height, width] + entropy-coded scan`. Sizes are at most 255 pixels a side (one byte each in the
/// header).
public enum TinyThumbnailEncoder {
    /// The longest side of the thumbnails this encoder makes (Telegram's are about 40 pixels).
    public static let defaultSide = 40

    /// The stripped thumbnail of an image given as RGBA (8 bits a channel, `width * height * 4` bytes, row by row from
    /// the top). Nil for an empty or oversized image.
    public static func encode(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 255, height <= 255, rgba.count >= width * height * 4, let tables = Tables.shared else {
            return nil
        }
        // YCbCr (JFIF), at full resolution.
        let count = width * height
        var y = [Double](repeating: 0, count: count)
        var cb = [Double](repeating: 0, count: count)
        var cr = [Double](repeating: 0, count: count)
        for index in 0 ..< count {
            let r = Double(rgba[index * 4])
            let g = Double(rgba[index * 4 + 1])
            let b = Double(rgba[index * 4 + 2])
            y[index] = 0.299 * r + 0.587 * g + 0.114 * b
            cb[index] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
            cr[index] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
        }
        func sample(_ plane: [Double], _ x: Int, _ y: Int) -> Double {
            // Edge pixels repeat past the image (partial MCUs).
            return plane[min(y, height - 1) * width + min(x, width - 1)]
        }

        var writer = BitWriter()
        var previousDC = [0, 0, 0]
        let mcuColumns = (width + 15) / 16
        let mcuRows = (height + 15) / 16
        for mcuY in 0 ..< mcuRows {
            for mcuX in 0 ..< mcuColumns {
                let originX = mcuX * 16
                let originY = mcuY * 16
                // Four luminance blocks, left to right and top to bottom.
                for blockIndex in 0 ..< 4 {
                    let blockX = originX + (blockIndex % 2) * 8
                    let blockY = originY + (blockIndex / 2) * 8
                    var block = [Double](repeating: 0, count: 64)
                    for row in 0 ..< 8 {
                        for column in 0 ..< 8 {
                            block[row * 8 + column] = sample(y, blockX + column, blockY + row) - 128
                        }
                    }
                    encodeBlock(block, quantization: tables.luminanceQuantization, dc: tables.luminanceDC, ac: tables.luminanceAC, previousDC: &previousDC[0], writer: &writer)
                }
                // One chrominance block each, the mean of every 2 × 2 pixels.
                for (planeIndex, plane) in [cb, cr].enumerated() {
                    var block = [Double](repeating: 0, count: 64)
                    for row in 0 ..< 8 {
                        for column in 0 ..< 8 {
                            let x = originX + column * 2
                            let y = originY + row * 2
                            let mean = (sample(plane, x, y) + sample(plane, x + 1, y) + sample(plane, x, y + 1) + sample(plane, x + 1, y + 1)) / 4
                            block[row * 8 + column] = mean - 128
                        }
                    }
                    encodeBlock(block, quantization: tables.chrominanceQuantization, dc: tables.chrominanceDC, ac: tables.chrominanceAC, previousDC: &previousDC[1 + planeIndex], writer: &writer)
                }
            }
        }
        writer.flush()
        return Data([1, UInt8(height), UInt8(width)]) + writer.bytes
    }

    /// The complete JPEG of a stripped thumbnail, as Telegram's decoder rebuilds it (tests, diagnostics).
    public static func jpeg(fromStripped data: Data) -> Data? {
        guard data.count >= 3, data[data.startIndex] == 1, let header = Tables.headerPattern else {
            return nil
        }
        var result = header
        result.append(data.subdata(in: data.startIndex + 3 ..< data.endIndex))
        result.append(contentsOf: [0xff, 0xd9])
        result[164] = data[data.startIndex + 1]
        result[166] = data[data.startIndex + 2]
        return result
    }

    private static func encodeBlock(_ block: [Double], quantization: [Int], dc: HuffmanTable, ac: HuffmanTable, previousDC: inout Int, writer: inout BitWriter) {
        // Forward DCT (the 64 × 64 sum: these images are tiny).
        var coefficients = [Int](repeating: 0, count: 64)
        for v in 0 ..< 8 {
            for u in 0 ..< 8 {
                var sum = 0.0
                for row in 0 ..< 8 {
                    for column in 0 ..< 8 {
                        sum += block[row * 8 + column] * cosines[column * 8 + u] * cosines[row * 8 + v]
                    }
                }
                let cu = u == 0 ? 1.0 / 2.0.squareRoot() : 1.0
                let cv = v == 0 ? 1.0 / 2.0.squareRoot() : 1.0
                let value = 0.25 * cu * cv * sum
                coefficients[v * 8 + u] = Int((value / Double(quantization[v * 8 + u])).rounded())
            }
        }
        // DC: the difference from the previous block of the same component.
        let dcValue = coefficients[0]
        let difference = dcValue - previousDC
        previousDC = dcValue
        let dcCategory = category(difference)
        writer.write(dc.codes[dcCategory], length: dc.lengths[dcCategory])
        writer.write(bits(difference, category: dcCategory), length: dcCategory)
        // AC in zigzag order: runs of zeros, 16-zero runs (ZRL) and an end of block.
        var run = 0
        for index in 1 ..< 64 {
            let value = coefficients[zigzag[index]]
            if value == 0 {
                run += 1
                continue
            }
            while run > 15 {
                writer.write(ac.codes[0xf0], length: ac.lengths[0xf0])
                run -= 16
            }
            let acCategory = category(value)
            let symbol = (run << 4) | acCategory
            writer.write(ac.codes[symbol], length: ac.lengths[symbol])
            writer.write(bits(value, category: acCategory), length: acCategory)
            run = 0
        }
        if run > 0 {
            writer.write(ac.codes[0x00], length: ac.lengths[0x00])
        }
    }

    /// The number of bits of a value's magnitude (JPEG's size category).
    private static func category(_ value: Int) -> Int {
        var magnitude = abs(value)
        var bits = 0
        while magnitude > 0 {
            bits += 1
            magnitude >>= 1
        }
        return bits
    }

    /// A value's extra bits: as is when positive, the one's complement of its magnitude when negative.
    private static func bits(_ value: Int, category: Int) -> Int {
        if value >= 0 {
            return value
        }
        return (value - 1) & ((1 << category) - 1)
    }

    private static let cosines: [Double] = (0 ..< 64).map { index in
        let x = Double(index / 8)
        let u = Double(index % 8)
        return cos((2 * x + 1) * u * Double.pi / 16)
    }

    /// Natural-order index of each zigzag position.
    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    struct HuffmanTable {
        /// Code and length per symbol (length 0: the symbol has no code).
        var codes = [Int](repeating: 0, count: 256)
        var lengths = [Int](repeating: 0, count: 256)

        /// A table from a DHT segment's counts per length (16 bytes) and symbols, with canonical codes.
        init(counts: [UInt8], symbols: [UInt8]) {
            var code = 0
            var symbolIndex = 0
            for length in 1 ... 16 {
                for _ in 0 ..< Int(counts[length - 1]) {
                    let symbol = Int(symbols[symbolIndex])
                    self.codes[symbol] = code
                    self.lengths[symbol] = length
                    symbolIndex += 1
                    code += 1
                }
                code <<= 1
            }
        }
    }

    /// The tables of the fixed header, read from the header itself so the encoder always matches the decoder.
    struct Tables {
        var luminanceQuantization: [Int]
        var chrominanceQuantization: [Int]
        var luminanceDC: HuffmanTable
        var luminanceAC: HuffmanTable
        var chrominanceDC: HuffmanTable
        var chrominanceAC: HuffmanTable

        /// TinyThumbnail's `tinyThumbnailHeaderPattern` (the SOI to the start of the scan).
        static let headerPattern = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwA=")

        static let shared: Tables? = {
            guard let header = headerPattern else {
                return nil
            }
            let bytes = [UInt8](header)
            var quantization: [Int: [Int]] = [:]
            var huffman: [Int: HuffmanTable] = [:]
            var index = 2
            while index + 4 <= bytes.count, bytes[index] == 0xff {
                let marker = bytes[index + 1]
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                let start = index + 4
                let end = index + 2 + length
                guard end <= bytes.count else {
                    return nil
                }
                if marker == 0xdb {
                    var offset = start
                    while offset + 65 <= end {
                        let tableId = Int(bytes[offset] & 0x0f)
                        var natural = [Int](repeating: 1, count: 64)
                        for position in 0 ..< 64 {
                            natural[zigzag[position]] = Int(bytes[offset + 1 + position])
                        }
                        quantization[tableId] = natural
                        offset += 65
                    }
                } else if marker == 0xc4 {
                    var offset = start
                    while offset + 17 <= end {
                        let classAndId = Int(bytes[offset])
                        let counts = Array(bytes[offset + 1 ..< offset + 17])
                        let total = counts.reduce(0) { $0 + Int($1) }
                        guard offset + 17 + total <= end else {
                            return nil
                        }
                        huffman[classAndId] = HuffmanTable(counts: counts, symbols: Array(bytes[offset + 17 ..< offset + 17 + total]))
                        offset += 17 + total
                    }
                } else if marker == 0xda {
                    break
                }
                index = end
            }
            guard let lq = quantization[0], let cq = quantization[1], let ldc = huffman[0x00], let lac = huffman[0x10], let cdc = huffman[0x01], let cac = huffman[0x11] else {
                return nil
            }
            return Tables(luminanceQuantization: lq, chrominanceQuantization: cq, luminanceDC: ldc, luminanceAC: lac, chrominanceDC: cdc, chrominanceAC: cac)
        }()
    }

    /// Bits into bytes, most significant first, with JPEG's byte stuffing (a 0x00 after every 0xFF).
    struct BitWriter {
        var bytes: [UInt8] = []
        private var buffer = 0
        private var count = 0

        mutating func write(_ value: Int, length: Int) {
            guard length > 0 else {
                return
            }
            for shift in stride(from: length - 1, through: 0, by: -1) {
                buffer = (buffer << 1) | ((value >> shift) & 1)
                count += 1
                if count == 8 {
                    emit()
                }
            }
        }

        /// Pads the last byte with one bits, as JPEG requires.
        mutating func flush() {
            while count != 0 {
                buffer = (buffer << 1) | 1
                count += 1
                if count == 8 {
                    emit()
                }
            }
        }

        private mutating func emit() {
            let byte = UInt8(buffer & 0xff)
            bytes.append(byte)
            if byte == 0xff {
                bytes.append(0)
            }
            buffer = 0
            count = 0
        }
    }
}
