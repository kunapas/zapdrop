# Zapdrop

*Android files to your Mac, in a zap!*

**Copy photos, videos and files from an Android phone to your Mac over USB.**
Free, open source, private, and with no artificial limits.

- No account, subscription, payment, ads, telemetry or cloud. Zapdrop never touches the network.
- No limits on file size, file count or speed. Files over 4 GB are supported (see *Limits* below).
- No ADB, USB debugging, companion app or root on the phone — just "File transfer" mode.
- Copies are written safely: to a temporary `.zapdroppart` file first, checked, then moved into place.

> Status: **pre-release (0.1.0)**. The transfer engine, mock phone and libmtp bridge are built and tested
> automatically. The macOS interface is built by CI; real-phone testing follows
> [`docs/DEVICE_TEST_CHECKLIST.md`](docs/DEVICE_TEST_CHECKLIST.md). Please report phones that misbehave.

## Install

1. Download the latest **Zapdrop** disk image (`.dmg`) from [Releases](https://github.com/kunapas/zapdrop/releases/latest).
2. Open it and drag **Zapdrop** into your Applications folder.
3. Open Zapdrop. The first time, macOS says it can't verify the app, because this build isn't signed with an Apple
   developer certificate yet. To allow it: open **System Settings → Privacy & Security**, scroll down to the
   message about Zapdrop and click **Open Anyway**. You only do this once.

Prefer the Terminal? This does the same as step 3:

```bash
xattr -dr com.apple.quarantine /Applications/Zapdrop.app
```

## Using Zapdrop

1. Open Zapdrop and connect your phone with a USB cable that supports data.
2. Unlock the phone, swipe down, tap the USB notification and choose **File transfer**
   (sometimes "File Transfer / Android Auto" or "MTP").
3. Pick a storage area (Internal storage, SD card) at the top of the window and browse like Finder.
4. Select files or folders, choose **Save To → Choose…**, then **Copy to Mac** (⇧⌘C).
5. Watch progress, speed and time remaining at the bottom. Cancel any time; finished files are kept.
6. If something fails, use **Retry Failed** — only the failed files are copied again.

More:
- **Quick Look**: select a file and press Space (or right-click → Quick Look, or ⌘Y).
- **Drag to Finder**: drag files or folders onto the Desktop or a Finder window to copy them there.
- **Copy to the phone**: drag files or folders from Finder into the window, copy them in Finder and paste
  (⌘V or right-click → Paste), or use **Copy to Phone** in the toolbar. Zapdrop only adds: a name that's already taken gets a number, and nothing on the phone is
  overwritten or deleted. Files of 4 GB or more can't be sent.
- **Phone details**: the top of the window shows the connected phone's storage, battery level and USB speed.
- **Space tips**: folders with big videos, old camera photos, screenshots, installers and the like show a tip,
  with **Select These** so you can copy them before deleting them on the phone.
- **Eject** (⏏ next to the phone, or ⌘E) before unplugging, or to let another app use the phone.

macOS's camera service grabs phones as soon as they're plugged in; Zapdrop takes the phone back automatically.
If an app of yours has it (Photos, Image Capture, Android File Transfer, Smart Switch, OpenMTP…), Zapdrop names it
and offers **Free Up Phone & Connect** — tick **Always do this automatically** and it won't ask again.
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

- **Try it without a phone:** `open dist/Zapdrop.app --args --mock` (or run with `ZAPDROP_MOCK=1`).
- **UI work without building libmtp:** `ZAPDROP_MOCK_ONLY=1 Scripts/build-app.sh`.
- **Xcode:** run `Scripts/build-deps.sh` once, then open `App/Zapdrop.xcodeproj` and run the *Zapdrop* scheme
  (enable the `--mock` argument in the scheme to use the simulated phone).
- **Release build** (Developer ID, notarised DMG): see [`docs/RELEASING.md`](docs/RELEASING.md).

## Project layout

| Path | What |
|---|---|
| `Sources/ZapdropCore` | Models, transfer engine, file safety, error messages (no UI, no USB) |
| `Sources/ZapdropMock` | Simulated phone for development and tests |
| `Sources/CZapdropMTP` | Small C layer: the only code that touches libmtp/libusb |
| `Sources/ZapdropLibMTP` | Real phone backend built on the C layer |
| `Sources/ZapdropAppModel` | View models: browsing, devices, transfers, settings |
| `App/Zapdrop` | SwiftUI app (macOS only) |
| `docs/` | [Architecture](docs/ARCHITECTURE.md), [decisions](docs/DECISIONS.md), [feasibility](docs/FEASIBILITY.md), [plan](docs/PLAN.md), [testing](docs/TESTING.md) |

## Support Zapdrop

Zapdrop is free and always will be. If it saves you time, you can buy the maintainer a coffee from
**Zapdrop › Buy Me a Coffee…** (also in the Help menu and About).

Building your own copy? The link is one setting: `SUPPORT_URL` in `Scripts/config.sh` (or
`ZAPDROP_SUPPORT_URL=https://… Scripts/build-app.sh`). Leave it empty and the menu items disappear.

## Privacy

Zapdrop works entirely on your Mac and makes no network requests. Read [`PRIVACY.md`](PRIVACY.md).

## Licence

Zapdrop is MIT-licensed ([`LICENSE`](LICENSE)). It bundles libmtp and libusb, which are LGPL-2.1-or-later,
unmodified and dynamically linked. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
"Android" is a trademark of Google LLC; Zapdrop is not affiliated with Google.
