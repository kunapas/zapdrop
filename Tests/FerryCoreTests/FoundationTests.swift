import XCTest
@testable import FerryCore
import FerryMock

final class FileNameSanitizerTests: XCTestCase {
    func testPlainNamesAreUnchanged() {
        let r = FileNameSanitizer.sanitize("PXL_20251009_101500.jpg")
        XCTAssertEqual(r.name, "PXL_20251009_101500.jpg")
        XCTAssertFalse(r.wasChanged)
    }

    func testSeparatorsAndTraversalAreNeutralised() {
        XCTAssertEqual(FileNameSanitizer.sanitize("../../etc/passwd").name, ".._.._etc_passwd")
        XCTAssertEqual(FileNameSanitizer.sanitize("a/b").name, "a_b")
        XCTAssertEqual(FileNameSanitizer.sanitize("backup:2025.zip").name, "backup_2025.zip")
        XCTAssertEqual(FileNameSanitizer.sanitize("..").name, FileNameSanitizer.placeholder)
        XCTAssertEqual(FileNameSanitizer.sanitize(".").name, FileNameSanitizer.placeholder)
        XCTAssertEqual(FileNameSanitizer.sanitize("   ").name, FileNameSanitizer.placeholder)
        XCTAssertEqual(FileNameSanitizer.sanitize("").name, FileNameSanitizer.placeholder)
    }

    func testControlAndBidiCharactersAreReplaced() {
        XCTAssertEqual(FileNameSanitizer.sanitize("a\u{0}b\nc").name, "a_b_c")
        let spoof = FileNameSanitizer.sanitize("invoice\u{202E}fdp.exe")
        XCTAssertEqual(spoof.name, "invoice_fdp.exe")
        XCTAssertTrue(spoof.wasChanged)
    }

    func testHiddenFilesKeepLeadingDot() {
        XCTAssertEqual(FileNameSanitizer.sanitize(".nomedia").name, ".nomedia")
    }

    func testUnicodeIsNormalisedToNFC() {
        let decomposed = "Re\u{0301}sume\u{0301}.pdf"
        let r = FileNameSanitizer.sanitize(decomposed)
        XCTAssertEqual(Array(r.name.unicodeScalars), Array("Résumé.pdf".precomposedStringWithCanonicalMapping.unicodeScalars))
    }

    func testLongNamesAreTruncatedToByteLimitKeepingExtension() {
        let long = String(repeating: "é", count: 300) + ".jpeg"
        let r = FileNameSanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(r.name.utf8.count, 255)
        XCTAssertTrue(r.name.hasSuffix(".jpeg"))
        XCTAssertTrue(r.name.hasPrefix("ééé"))
        // Emoji grapheme clusters are never split.
        let emoji = String(repeating: "👨‍👩‍👧", count: 40) + ".png"
        let e = FileNameSanitizer.sanitize(emoji).name
        XCTAssertLessThanOrEqual(e.utf8.count, 255)
        XCTAssertTrue(e.hasSuffix(".png"))
        XCTAssertTrue(e.dropLast(4).allSatisfy { $0 == "👨‍👩‍👧" })
    }

    func testNumberedVariants() {
        XCTAssertEqual(FileNameSanitizer.numberedVariant(of: "photo.jpg", number: 1), "photo (1).jpg")
        XCTAssertEqual(FileNameSanitizer.numberedVariant(of: ".nomedia", number: 2), ".nomedia (2)")
        XCTAssertEqual(FileNameSanitizer.numberedVariant(of: "archive.tar.gz", number: 1), "archive.tar (1).gz")
        XCTAssertEqual(FileNameSanitizer.numberedVariant(of: "README", number: 3), "README (3)")
        let long = String(repeating: "a", count: 251) + ".jpg"
        XCTAssertLessThanOrEqual(FileNameSanitizer.numberedVariant(of: long, number: 12).utf8.count, 255)
    }

    func testCollisionKeys() {
        XCTAssertEqual(FileNameSanitizer.collisionKey("Notes.txt", caseSensitive: false),
                       FileNameSanitizer.collisionKey("notes.txt", caseSensitive: false))
        XCTAssertNotEqual(FileNameSanitizer.collisionKey("Notes.txt", caseSensitive: true),
                          FileNameSanitizer.collisionKey("notes.txt", caseSensitive: true))
        XCTAssertEqual(FileNameSanitizer.collisionKey("Re\u{0301}sume\u{0301}", caseSensitive: true),
                       FileNameSanitizer.collisionKey("Résumé", caseSensitive: true))
    }

    func testSafePathStaysInsideRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/ferry-root")
        XCTAssertEqual(try SafePath.join(root: root, components: ["DCIM", "a.jpg"]).path, "/tmp/ferry-root/DCIM/a.jpg")
        XCTAssertThrowsError(try SafePath.join(root: root, components: [".."]))
        XCTAssertThrowsError(try SafePath.join(root: root, components: ["a/../../b"]))
        XCTAssertThrowsError(try SafePath.join(root: root, components: [""]))
    }

    func testDisplayTextStripsControls() {
        XCTAssertEqual(DisplayText.clean(" Sam\u{202E}'s\n Pixel "), "Sam's Pixel")
    }
}

final class ByteMathTests: XCTestCase {
    func testSizesAbove4GBAreExact() {
        let fiveGiB: UInt64 = 5 * 1024 * 1024 * 1024
        XCTAssertGreaterThan(fiveGiB, UInt64(UInt32.max))
        var total: UInt64 = 0
        for _ in 0..<10 { total = ProgressMath.add(total, fiveGiB) }
        XCTAssertEqual(total, 53_687_091_200)
        XCTAssertEqual(ProgressMath.add(.max - 1, 10), .max) // saturates, never traps
    }

    func testProgressFraction() {
        XCTAssertEqual(ProgressMath.fraction(done: 0, total: 0), 0)
        XCTAssertEqual(ProgressMath.fraction(done: 5, total: 0), 1)
        XCTAssertEqual(ProgressMath.fraction(done: 50, total: 100), 0.5)
        XCTAssertEqual(ProgressMath.fraction(done: 200, total: 100), 1)
        let big = UInt64.max
        XCTAssertEqual(ProgressMath.fraction(done: big / 2, total: big), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ProgressMath.fraction(done: 4_294_967_296, total: 8_589_934_592), 0.5)
        XCTAssertEqual(ProgressMath.remaining(done: 10, total: 4), 0)
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteFormatter.string(0), "0 bytes")
        XCTAssertEqual(ByteFormatter.string(1), "1 byte")
        XCTAssertEqual(ByteFormatter.string(999), "999 bytes")
        XCTAssertEqual(ByteFormatter.string(1_000), "1 KB")
        XCTAssertEqual(ByteFormatter.string(1_500_000), "1.5 MB")
        XCTAssertEqual(ByteFormatter.string(5_368_709_120), "5.4 GB")
        XCTAssertEqual(ByteFormatter.string(999_999), "1 MB")
        XCTAssertEqual(ByteFormatter.string(UInt64.max), "18 EB")
        XCTAssertEqual(ByteFormatter.rate(35_000_000), "35 MB/s")
        XCTAssertEqual(ByteFormatter.duration(nil), "Calculating…")
        XCTAssertEqual(ByteFormatter.duration(42), "About 42 seconds")
        XCTAssertEqual(ByteFormatter.duration(3_720), "About 1 h 2 min")
    }

    func testSpeedEstimatorAndETA() {
        var s = SpeedEstimator(smoothing: 1, minimumInterval: 0)
        s.record(totalBytes: 0, at: 0)
        s.record(totalBytes: 10_000_000, at: 1)
        XCTAssertEqual(s.bytesPerSecond, 10_000_000)
        XCTAssertEqual(s.secondsRemaining(remainingBytes: 50_000_000), 5)
        var fresh = SpeedEstimator()
        XCTAssertNil(fresh.secondsRemaining(remainingBytes: 1))
        fresh.record(totalBytes: 5, at: 0)
        fresh.record(totalBytes: 10, at: 0.1) // too soon — ignored
        XCTAssertEqual(fresh.bytesPerSecond, 0)
    }
}

final class SHA256Tests: XCTestCase {
    private func hex(_ s: String) -> String {
        var h = SHA256Hasher(); h.update(Data(s.utf8)); return SHA256Hasher.hex(h.finalize())
    }

    func testNISTVectors() {
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testStreamingMatchesOneShot() {
        let data = MockContent.bytes(offset: 123, count: 300_001, seed: 7)
        var one = SHA256Hasher(); one.update(Data(data))
        var many = SHA256Hasher()
        var i = 0
        for size in [1, 63, 64, 65, 1000, 4096] where i < data.count {
            let end = min(data.count, i + size)
            data[i..<end].withUnsafeBytes { many.update($0) }
            i = end
        }
        data[i...].withUnsafeBytes { many.update($0) }
        XCTAssertEqual(one.finalize(), many.finalize())
    }

    func testMillionAs() {
        var h = SHA256Hasher()
        let chunk = Data(repeating: 0x61, count: 1000)
        for _ in 0..<1000 { h.update(chunk) }
        XCTAssertEqual(SHA256Hasher.hex(h.finalize()), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

final class ErrorMapperTests: XCTestCase {
    func testEveryErrorHasFriendlyText() {
        let all: [FerryError] = [.noDevice, .chargingOnlyMode, .deviceLocked, .notAuthorized, .deviceBusy(holder: "Photos"),
                                 .multipleDevices, .deviceDisconnected, .unsupportedDevice(detail: "x"),
                                 .protocolError(detail: "PTP 0x2002"), .sourceRemoved, .sourceChanged, .sizeUnknown,
                                 .destinationUnavailable, .insufficientSpace(needed: 10_000_000_000, available: 1_000),
                                 .permissionDenied, .invalidFileName, .destinationConflict(name: "DCIM"),
                                 .unsafeDestinationPath, .sizeMismatch(expected: 2, actual: 1), .verificationFailed,
                                 .cancelled, .io(detail: "EIO")]
        for e in all {
            let u = ErrorMapper.map(e)
            XCTAssertFalse(u.title.isEmpty)
            XCTAssertFalse(u.message.isEmpty)
            // Raw technical detail never reaches the user.
            XCTAssertFalse(u.message.contains("PTP 0x2002"))
            XCTAssertFalse(u.message.contains("EIO"))
        }
        XCTAssertTrue(ErrorMapper.map(.deviceBusy(holder: "Photos")).message.contains("Photos"))
        XCTAssertTrue(ErrorMapper.map(.insufficientSpace(needed: 10_000_000_000, available: 1_000)).message.contains("10 GB"))
    }

    func testErrnoMapping() {
        XCTAssertEqual(FerryError.fromErrno(ENOSPC, context: "x"), .insufficientSpace(needed: 0, available: 0))
        XCTAssertEqual(FerryError.fromErrno(EACCES, context: "x"), .permissionDenied)
        XCTAssertEqual(FerryError.fromErrno(EEXIST, context: "x"), .destinationConflict(name: "x"))
        XCTAssertEqual(FerryError.fromErrno(ELOOP, context: "x"), .unsafeDestinationPath)
    }
}

final class FileKindTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(FileKind.classify(fileName: "a.JPG", isFolder: false), .photo)
        XCTAssertEqual(FileKind.classify(fileName: "a.heic", isFolder: false), .photo)
        XCTAssertEqual(FileKind.classify(fileName: "v.MP4", isFolder: false), .video)
        XCTAssertEqual(FileKind.classify(fileName: "s.opus", isFolder: false), .audio)
        XCTAssertEqual(FileKind.classify(fileName: "r.pdf", isFolder: false), .document)
        XCTAssertEqual(FileKind.classify(fileName: ".nomedia", isFolder: false), .other)
        XCTAssertEqual(FileKind.classify(fileName: "DCIM", isFolder: true), .folder)
        XCTAssertEqual(FileKind.classify(fileName: "noext", isFolder: false), .other)
    }
}
