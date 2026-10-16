import Foundation

/// Deterministic file contents of any length without storing them. Byte at offset `o` of a file with
/// seed `s` is `pattern[(o + s) % pattern.count]`. Tests use the same function to compute expected data.
public enum MockContent {
    static let pattern: [UInt8] = {
        var p = [UInt8](repeating: 0, count: 65_521) // prime length so offsets don't align with chunk sizes
        var x: UInt32 = 0x9E37_79B9
        for i in 0..<p.count {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            p[i] = UInt8(truncatingIfNeeded: x)
        }
        return p
    }()

    /// Fills `buffer` with the bytes at `offset…` of the file with `seed`.
    public static func fill(_ buffer: UnsafeMutableRawBufferPointer, offset: UInt64, seed: UInt32) {
        let n = pattern.count
        var start = Int((offset &+ UInt64(seed)) % UInt64(n))
        var written = 0
        pattern.withUnsafeBytes { src in
            while written < buffer.count {
                let take = min(n - start, buffer.count - written)
                (buffer.baseAddress! + written).copyMemory(from: src.baseAddress! + start, byteCount: take)
                written += take
                start = 0
            }
        }
    }

    public static func bytes(offset: UInt64, count: Int, seed: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        out.withUnsafeMutableBytes { fill($0, offset: offset, seed: seed) }
        return out
    }
}

/// Tiny PNG encoder (uncompressed deflate) so the mock phone can offer real thumbnails.
enum MockPNG {
    static func gradient(width: Int = 96, height: Int = 96, seed: UInt32) -> Data {
        let r0 = UInt8(truncatingIfNeeded: seed &* 37), g0 = UInt8(truncatingIfNeeded: seed &* 91), b0 = UInt8(truncatingIfNeeded: seed &* 13)
        var raw = [UInt8]()
        raw.reserveCapacity((width * 3 + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none
            for x in 0..<width {
                raw.append(r0 &+ UInt8(x * 2)); raw.append(g0 &+ UInt8(y * 2)); raw.append(b0 &+ UInt8((x + y)))
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(UInt32(width))); ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func zlibStored(_ data: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        var i = 0
        repeat {
            let len = min(65_535, data.count - i)
            let final: UInt8 = i + len >= data.count ? 1 : 0
            out.append(final)
            out.append(UInt8(len & 0xFF)); out.append(UInt8(len >> 8))
            out.append(UInt8(~len & 0xFF)); out.append(UInt8((~len >> 8) & 0xFF))
            out.append(contentsOf: data[i..<(i + len)])
            i += len
        } while i < data.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        out.append(be32(b << 16 | a))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var d = be32(UInt32(body.count))
        let typed = Data(type.utf8) + body
        d.append(typed)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typed { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        d.append(be32(crc ^ 0xFFFF_FFFF))
        return d
    }

    private static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
}
