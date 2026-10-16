# Feasibility assessment

_Last reviewed: 16 October 2026_

## Short answer

Feasible. A native, free, offline macOS app can browse and copy files from Android phones over USB using
**MTP** through **libmtp + libusb**, bundled inside the app. There is one serious platform risk
(macOS's own `ptpcamerad` grabbing the phone) that cannot be fully engineered away; it can be detected
and explained, with a one-click, user-initiated fix.

## What macOS gives us natively

| Option | General file access? | Notes |
|---|---|---|
| Finder | No | macOS has no built-in MTP support. |
| ImageCaptureCore | **No** | Exposes camera-style media (PTP), typically only `DCIM` photos/videos. Cannot browse `Download/`, `Documents/`, WhatsApp folders, etc. Not suitable as the main backend. |
| Android File Transfer (Google) | Yes, but discontinued | Closed source, no longer maintained, and itself competes for the device. |

So a third-party MTP stack is required.

## MTP implementation options

| Option | Language / licence | Maturity | Large files (>4 GB) | Bundling | Verdict |
|---|---|---|---|---|---|
| **libmtp 1.1.23** + libusb 1.0.29 | C / LGPL-2.1-or-later (both) | 20+ years, large device-quirks database; used by gvfs, KDE, OpenMTP | 64-bit sizes in API (`uint64_t filesize`); streams via `LIBMTP_Get_File_To_Handler` | Build universal (arm64 + x86_64) `.dylib`s, ship in `Contents/Frameworks` — no Homebrew needed | **Chosen** |
| mtp-rs | Rust / MIT or Apache-2.0 | Young (0.x, fast-moving), modern-Android focus, async, reportedly faster | Yes, 64-bit partial reads | Needs Rust toolchain + C-ABI wrapper | Strong future alternative; documented as plan B |
| android-file-transfer-linux | C++ / LGPL-2.1 | Mature, own MTP stack | Yes | Qt-oriented, Homebrew formula; harder to embed cleanly | Not chosen |
| Write our own MTP in Swift over IOKit | Our licence | None (would start from zero) | Our responsibility | Simple | Too risky for v1; device quirks are the hard part |

Why libmtp: it is the most battle-tested option against real-world device quirks, its C API maps cleanly to
a tiny shim, and the LGPL is fully compatible with an MIT-licensed app **as long as libmtp and libusb are
dynamically linked and their source is offered** (see `THIRD_PARTY_NOTICES.md`). The device layer sits behind
a Swift protocol (`DeviceBackend`), so swapping to mtp-rs or a native implementation later does not touch
the UI or transfer engine.

### libmtp checklist

1. **macOS + modern Android** — yes; libmtp uses libusb, which supports macOS (IOKit) on Apple Silicon and Intel.
2. **Enumerate storage, folders, files** — yes: `LIBMTP_Get_Storage`, `LIBMTP_Get_Files_And_Folders` (lazy, one folder at a time, with `LIBMTP_Open_Raw_Device_Uncached`).
3. **Stream large files** — yes: `LIBMTP_Get_File_To_Handler` hands us chunks; we write each one straight to disk. Memory stays flat.
4. **Licence** — LGPL-2.1-or-later. Obligations: dynamic linking, ship licence text, offer corresponding source. Done by the build scripts and notices.
5. **Bundle without Homebrew** — yes: `Scripts/build-deps.sh` builds pinned source tarballs into universal dylibs with `@rpath` install names.
6. **Apple Silicon + Intel** — yes, built as universal binaries (`lipo`).
7. **Known limitations** — see below.

## Known platform and device limitations (honest list)

- **`ptpcamerad` / Image Capture contention.** On connect, macOS's camera daemon (and apps like Photos,
  Image Capture, Android File Transfer, Samsung Smart Switch, OpenMTP) may claim the phone's USB interface.
  Only one program can use it at a time. Ferry detects this, names the likely holder, and offers a
  user-initiated "Release phone from macOS camera service" button (it ends the user's own `ptpcamerad`
  process, which macOS restarts later). This is why Ferry is **not sandboxed** in v1 (see Decisions).
- **MTP is one-request-at-a-time.** Ferry runs one device operation at a time. Parallel copies would not be faster
  and break some phones.
- **No source checksums.** Android's MTP server does not expose file hashes. Ferry verifies byte counts and can
  optionally re-read the written file to confirm it matches what arrived over USB, but it **cannot**
  cryptographically prove the file equals the phone's copy.
- **Files >4 GB** depend on the phone reporting 64-bit sizes (MTP object property `ObjectSize`). Modern
  Android does; very old or unusual devices may report 4 GB and fail. Needs real-device verification.
- **Locked phone / permission prompt.** Android hides storage until the phone is unlocked (and on some brands
  until "Allow access to phone data" is tapped). MTP cannot tell these two apart; Ferry shows one combined
  instruction.
- **Case and Unicode collisions.** Android folders are case-sensitive; the default Mac disk is not. Two
  phone files `IMG.jpg` and `img.jpg` become a name clash on the Mac. Ferry detects and renames these.
- **Modification dates** are preserved when the phone reports them. Creation dates usually are not available over MTP.
- **Thumbnails** come from the phone where it supports MTP thumbnails (most JPEGs). Other images are
  thumbnailed by downloading small files only (size-capped). Video thumbnails are not generated in v1.

## Development-environment constraints for this build

- The Mac this was prepared for does not have Xcode installed. The app layer (SwiftUI, IOKit) can only be
  compiled on macOS with Xcode or the Command Line Tools.
- All platform-independent code (models, transfer engine, planner, sanitiser, mock backend, view models,
  libmtp bridge) is compiled and unit-tested on Linux with Swift 6.1.3 against the real libmtp 1.1.22
  headers. The macOS-only parts are kept small and are built by CI on a macOS runner.
