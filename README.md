# Zapdrop

**Copy photos, videos and files from an Android phone to your Mac over USB.**
Free, open source, private, and with no artificial limits.

- No account, subscription, payment, ads, telemetry or cloud. Zapdrop never touches the network.
- No limits on file size, file count or speed. Files over 4 GB are supported (see *Limits* below).
- No ADB, USB debugging, companion app or root on the phone — just "File transfer" mode.
- Copies are written safely: to a temporary `.zapdroppart` file first, checked, then moved into place.

> Status: **pre-release (0.1.0)**. The transfer engine, mock phone and libmtp bridge are built and tested
> automatically. The macOS interface is built by CI; real-phone testing follows
> [`docs/DEVICE_TEST_CHECKLIST.md`](docs/DEVICE_TEST_CHECKLIST.md). Please report phones that misbehave.

## Using Zapdrop

1. Open Zapdrop and connect your phone with a USB cable that supports data.
2. Unlock the phone, swipe down, tap the USB notification and choose **File transfer**
   (sometimes "File Transfer / Android Auto" or "MTP").
3. Pick a storage area (Internal storage, SD card) in the sidebar and browse like Finder.
4. Select files or folders, choose **Save To → Choose…**, then **Copy to Mac** (⇧⌘C).
5. Watch progress, speed and time remaining at the bottom. Cancel any time; finished files are kept.
6. If something fails, use **Retry Failed** — only the failed files are copied again.

More:
- **Quick Look**: select a file and press Space (or right-click → Quick Look, or ⌘Y).
- **Drag to Finder**: drag files or folders onto the Desktop or a Finder window to copy them there.
- **Phone details**: the sidebar shows the connected phone's storage, battery level and USB speed.
- **Space tips**: folders with big videos, old camera photos, screenshots, installers and the like show a tip,
  with **Select These** so you can copy them before deleting them on the phone.
- **Eject** (⏏ next to the phone, or ⌘E) before unplugging, or to let another app use the phone.

If Zapdrop says the phone is **in use by another app**, quit Image Capture, Photos, Android File Transfer,
Samsung Smart Switch or OpenMTP. If it still won't connect, click **Release Phone from macOS Camera Service**.
More help: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Limits (honestly)

There is no limit inside Zapdrop. Real limits come from:

- **Your Mac's free space** — checked before copying starts and again before each file.
- **The destination file system** — e.g. FAT32 USB sticks can't hold files of 4 GB or more.
- **The phone's MTP implementation** — files of 4 GB+ need the phone to support 64-bit partial reads
  (modern Android does). Zapdrop tells you plainly if a phone can't send such a file.
- **USB and MTP speed** — MTP handles one request at a time, so Zapdrop copies one file at a time.

Android does not provide checksums over MTP. Zapdrop always checks the byte count. The optional
**Verify each file after copying** setting re-reads each saved file to confirm the Mac's copy is intact. It
cannot prove the phone's copy was intact, and Zapdrop doesn't claim otherwise.

## Building

You need a Mac with macOS 14 or newer and either Xcode 16+ or just the Command Line Tools. Running the tests
(`swift test`) needs full Xcode, because the Command Line Tools don't include XCTest.

```sh
# one-time: tools to build the bundled libmtp/libusb from pinned source
brew install autoconf automake libtool pkg-config gettext

Scripts/build-deps.sh     # builds universal libmtp + libusb into Vendor/build (5–10 minutes)
swift test                # runs the automated tests
Scripts/build-app.sh      # creates dist/Zapdrop.app (ad-hoc signed; runs on this Mac)
open dist/Zapdrop.app
```

- **Try it without a phone:** `open dist/Zapdrop.app --args --mock` (or run with `FERRY_MOCK=1`).
- **UI work without building libmtp:** `FERRY_MOCK_ONLY=1 Scripts/build-app.sh`.
- **Xcode:** run `Scripts/build-deps.sh` once, then open `App/Ferry.xcodeproj` and run the *Ferry* scheme
  (enable the `--mock` argument in the scheme to use the simulated phone).
- **Release build** (Developer ID, notarised DMG): see [`docs/RELEASING.md`](docs/RELEASING.md).

## Project layout

| Path | What |
|---|---|
| `Sources/FerryCore` | Models, transfer engine, file safety, error messages (no UI, no USB) |
| `Sources/FerryMock` | Simulated phone for development and tests |
| `Sources/CFerryMTP` | Small C layer: the only code that touches libmtp/libusb |
| `Sources/FerryLibMTP` | Real phone backend built on the C layer |
| `Sources/FerryAppModel` | View models: browsing, devices, transfers, settings |
| `App/Ferry` | SwiftUI app (macOS only) |
| `docs/` | [Architecture](docs/ARCHITECTURE.md), [decisions](docs/DECISIONS.md), [feasibility](docs/FEASIBILITY.md), [plan](docs/PLAN.md), [testing](docs/TESTING.md) |

## Privacy

Zapdrop works entirely on your Mac and makes no network requests. Read [`PRIVACY.md`](PRIVACY.md).

## Licence

Zapdrop is MIT-licensed ([`LICENSE`](LICENSE)). It bundles libmtp and libusb, which are LGPL-2.1-or-later,
unmodified and dynamically linked. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
"Android" is a trademark of Google LLC; Zapdrop is not affiliated with Google.
