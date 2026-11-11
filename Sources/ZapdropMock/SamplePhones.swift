import Foundation
import ZapdropCore

public enum SamplePhones {
    /// A realistic phone used by the app's demo mode (`--mock`) and by tests.
    public static func pixel(id: String = "mock-pixel") -> MockPhone {
        let phone = MockPhone(summary: DeviceSummary(id: DeviceID(id), manufacturer: "Google", model: "Pixel 9",
                                                     friendlyName: "Sam's Pixel", vendorID: 0x18D1, productID: 0x4EE1))
        let gb: UInt64 = 1_000_000_000
        let mb: UInt64 = 1_000_000
        let main = phone.addStorage("Internal shared storage", capacity: 256 * gb, free: 87 * gb)
        let base = Date(timeIntervalSince1970: 1_760_000_000) // Oct 2025

        let dcim = phone.addFolder("DCIM", storage: main, modified: base)
        let camera = phone.addFolder("Camera", in: dcim, storage: main, modified: base)
        for i in 0..<48 {
            let day = Double(i) * 86_400 / 3
            phone.addFile(String(format: "PXL_20251009_%06d.jpg", 101_500 + i * 37), in: camera, storage: main,
                          size: 2 * mb + UInt64(i) * 113_457, modified: base.addingTimeInterval(day))
            if i % 6 == 0 {
                phone.addFile(String(format: "PXL_20251009_%06d.mp4", 101_520 + i * 37), in: camera, storage: main,
                              size: 40 * mb + UInt64(i) * 3 * mb, modified: base.addingTimeInterval(day + 60))
            }
        }
        phone.addFile("PXL_20251012_LONG_TRIP.mp4", in: camera, storage: main, size: 5_368_709_120 + 12_345,
                      modified: base.addingTimeInterval(400_000)) // > 4 GiB
        phone.addFile("IMG_0001.HEIC", in: camera, storage: main, size: 3 * mb, modified: base)

        let pictures = phone.addFolder("Pictures", storage: main, modified: base)
        let shots = phone.addFolder("Screenshots", in: pictures, storage: main, modified: base)
        for i in 0..<12 {
            phone.addFile("Screenshot_20251010-\(String(format: "%06d", 90_000 + i * 11)).png", in: shots,
                          storage: main, size: 400_000 + UInt64(i) * 9_000, modified: base.addingTimeInterval(Double(i) * 3_600))
        }
        phone.addFolder("Empty album", in: pictures, storage: main, modified: base)

        let download = phone.addFolder("Download", storage: main, modified: base)
        phone.addFile("Boarding pass.pdf", in: download, storage: main, size: 180_000, modified: base)
        phone.addFile("Quarterly report v3.docx", in: download, storage: main, size: 1_250_000, modified: base)
        phone.addFile("notes.txt", in: download, storage: main, size: 2_048, modified: base)
        phone.addFile("Notes.txt", in: download, storage: main, size: 4_096, modified: base) // case clash on macOS
        phone.addFile("backup:2025.zip", in: download, storage: main, size: 25 * mb, modified: base)
        phone.addFile("invoice\u{202E}fdp.exe", in: download, storage: main, size: 10_000, modified: base) // bidi spoof
        phone.addFile("app-release.apk", in: download, storage: main, size: 48 * mb, modified: base)

        let docs = phone.addFolder("Documents", storage: main, modified: base)
        phone.addFile("Résumé.pdf", in: docs, storage: main, size: 220_000, modified: base)
        phone.addFile("Budget 2026.xlsx", in: docs, storage: main, size: 64_000, modified: nil)

        let music = phone.addFolder("Music", storage: main, modified: base)
        for (i, t) in ["Morning.mp3", "Commute.m4a", "Field recording.wav", "Voice note.ogg"].enumerated() {
            phone.addFile(t, in: music, storage: main, size: 4 * mb + UInt64(i) * mb, modified: base)
        }

        let wa = phone.addFolder("WhatsApp", storage: main, modified: base)
        let media = phone.addFolder("Media", in: wa, storage: main, modified: base)
        let waImages = phone.addFolder("WhatsApp Images", in: media, storage: main, modified: base)
        for i in 0..<20 {
            phone.addFile("IMG-20251001-WA\(String(format: "%04d", i)).jpg", in: waImages, storage: main,
                          size: 150_000 + UInt64(i) * 7_000, modified: base)
        }
        phone.addFile(".nomedia", in: media, storage: main, size: 0, modified: base)
        phone.addFolder("Android", storage: main, modified: base)

        let sd = phone.addStorage("SD card", capacity: 128 * gb, free: 100 * gb, removable: true)
        let sdDCIM = phone.addFolder("DCIM", storage: sd, modified: base)
        for i in 0..<6 {
            phone.addFile("DSC_\(1000 + i).JPG", in: sdDCIM, storage: sd, size: 6 * mb, modified: base)
        }
        return phone
    }

    public static func backend(throughputMBps: Double? = 35) -> MockDeviceBackend {
        let p = pixel()
        p.bytesPerSecond = throughputMBps.map { $0 * 1_000_000 }
        return MockDeviceBackend(phones: [p])
    }
}
