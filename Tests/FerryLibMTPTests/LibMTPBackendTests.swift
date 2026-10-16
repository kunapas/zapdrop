import XCTest
import FerryCore
import CFerryMTP
@testable import FerryLibMTP

/// These run without a phone: they prove the bridge links against the real libmtp/libusb and maps data safely.
/// Real-device behaviour is covered by docs/DEVICE_TEST_CHECKLIST.md.
final class LibMTPBackendTests: XCTestCase {
    func testLinksAgainstLibmtp() {
        let version = LibMTPBackend.libmtpVersion
        XCTAssertTrue(version.hasPrefix("1.1."), version)
    }

    func testDiscoveryWithoutPhonesDoesNotCrash() async {
        let backend = LibMTPBackend()
        do {
            let devices = try await backend.discover()
            XCTAssertTrue(devices.allSatisfy { $0.summary.vendorID != 0x05AC }, "Apple devices are ignored")
        } catch {
            // No USB access in some CI containers; a clean error is acceptable.
            XCTAssertTrue(error is FerryError)
        }
    }

    func testUSBAddressRoundTrip() {
        let a = USBAddress(bus: 20, address: 7, vendorID: 0x04E8, productID: 0x6860)
        XCTAssertEqual(a.deviceID.rawValue, "usb:20:7:4e8:6860")
        XCTAssertEqual(USBAddress(a.deviceID), a)
        XCTAssertNil(USBAddress(DeviceID("mock-pixel")))
        XCTAssertNil(USBAddress(DeviceID("usb:1:999:4e8:1")))
    }

    func testOpeningAMissingDeviceFailsCleanly() async {
        let backend = LibMTPBackend()
        do {
            _ = try await backend.openSession(USBAddress(bus: 250, address: 250, vendorID: 1, productID: 1).deviceID)
            XCTFail("should not open")
        } catch let e as FerryError {
            XCTAssertTrue([.deviceDisconnected, .notAuthorized, .noDevice].contains(e), "\(e)")
        } catch { XCTFail("\(error)") }
    }

    func testObjectConversion() {
        let name = strdup("PXL_1.mp4")
        defer { free(name) }
        var o = ferry_object()
        o.id = 42; o.parent_id = 0; o.storage_id = 0x10001; o.size = 0xFFFF_FFFF; o.mtime = 1_700_000_000
        o.is_folder = 0; o.name = name
        let item = LibMTPSession.item(from: o, location: RemoteLocation(storageID: 0x10001))
        XCTAssertNil(item.size, "0xFFFFFFFF means size unknown")
        XCTAssertEqual(item.parentID, rootParentID, "root children are normalised to the root parent ID")
        XCTAssertEqual(item.modified, Date(timeIntervalSince1970: 1_700_000_000))
        o.size = 6_000_000_000; o.mtime = 0
        let big = LibMTPSession.item(from: o, location: nil)
        XCTAssertEqual(big.size, 6_000_000_000)
        XCTAssertNil(big.modified)
        XCTAssertEqual(big.parentID, 0)
    }
}
