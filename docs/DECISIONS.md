# Key technical decisions

Short records of decisions that shape the code. Newest last.

## D1 — Name: "Zapdrop" (formerly "Ferry")
The app started as "Ferry" (short for moving things across; "OpenMTP Mac" was too close to OpenMTP). Before
publishing it was renamed **Zapdrop**: distinctive, quick to say, and with no existing app or trademark found under
that exact name (Oct 2026 web and App Store search). Names were rejected for: Apple marks ("Air…", "Mac" with a
generic word — Apple's trademark guidelines), Google marks ("Android", "Andro…", "Droid"), and existing apps or
software marks. Nearby but distinct: Zapya and Snapdrop (file-sharing tools). A formal USPTO/EUIPO class 9 search and
reserving the name in App Store Connect are still to do.
The user-facing name lives in `Scripts/config.sh` (`APP_NAME`, `BUNDLE_ID`), the Xcode project's `PRODUCT_NAME`,
`App/Support/Info.plist` and UI text. Internal code names keep "Ferry" (`FerryCore`, `CFerryMTP`, `ferry_*`,
`FERRY_*` switches, the `App/Ferry` folder and Xcode target) — renaming them would change nothing users see.

## D2 — Device layer: libmtp 1.1.23 + libusb 1.0.29, dynamically linked
See `FEASIBILITY.md`. Wrapped by a tiny C shim (`Sources/CFerryMTP`) and a Swift backend (`Sources/FerryLibMTP`).
Nothing else imports libmtp. The rest of the app talks to the `DeviceBackend` protocol.

## D3 — One serial device queue
libmtp is not thread-safe per device and many phones misbehave with overlapping requests. Every libmtp call
runs on one dedicated serial `DispatchQueue` (blocking is fine there; it is not Swift's cooperative pool).
Swift code awaits it through continuations. Cancellation sets a flag that libmtp's progress callback checks.

## D4 — Minimum macOS 14 (deviation from the requested macOS 13)
View models use the Observation framework (`@Observable`), which needs macOS 14 and is also available in the
Linux Swift toolchain — so view models can be unit-tested in CI without a Mac. macOS 13 no longer receives
security updates from Apple, so the trade-off is small. Reverting to 13 means swapping `@Observable` for
`ObservableObject`.

## D5 — Not sandboxed in v1; Developer ID + Hardened Runtime + notarisation
libusb does work under the App Sandbox with `com.apple.security.device.usb`, but a sandboxed app cannot end
`ptpcamerad`, which is the most common reason a phone "doesn't show up". v1 ships outside the Mac App Store,
signed with Developer ID, Hardened Runtime on, notarised, no network entitlements used. A sandboxed build
(`Ferry-Sandboxed.entitlements`) is kept for experimentation and must be verified on real hardware before use.

## D6 — Swift Package is the source of truth; Xcode project is a thin shell
All code lives in a Swift package. The app can be built with only the Command Line Tools
(`Scripts/build-app.sh`) or opened in Xcode (`App/Ferry.xcodeproj`, which references the package).
macOS-only targets are added to `Package.swift` only when building on macOS.

## D7 — Partial files next to the destination, then atomic rename
Each file is written to `<name>.zapdroppart` in the destination folder (same volume, so `rename` is atomic),
flushed with `fsync`, size-checked, dated, then renamed. If renaming would overwrite something the user did
not agree to replace, it fails rather than clobbering (`renamex_np(RENAME_EXCL)` on macOS). Partial files are
deleted on cancel or failure; any left behind by a crash are clearly named.

## D8 — Integrity: byte counts always, read-back verification optional
Android does not expose file hashes over MTP. Zapdrop always checks that bytes written == size the phone reported.
Optional "Verify after copying" computes SHA-256 while receiving, then re-reads the written file and compares.
This proves the Mac's copy is intact on disk — not that the phone's copy was intact. The UI says exactly that.

## D9 — Device discovery by polling libusb, not opening devices
Every 1.5 s Zapdrop lists USB devices (cheap, does not open them or disturb transfers). Only when the set changes does it
ask libmtp to probe. This avoids racing `ptpcamerad`, and lets Zapdrop spot a phone in "charging only" mode
(known phone vendor, no MTP interface).

## D10 — Licence: MIT for Zapdrop's own code
Permissive, compatible with dynamically linked LGPL libraries.

## D11 — No dependencies beyond libmtp/libusb
SHA-256 is implemented in-repo (validated against NIST vectors) rather than adding swift-crypto, because only
streaming hashing for read-back verification is needed. On macOS CryptoKit could replace it later.

## D12 — Files of 4 GiB or more are read in 64-bit windows
Reading libmtp's source (1.1.23, `ptp_usb_getdata`) shows the single-transfer `GetObject` path carries a
32-bit length, so a ≥4 GiB file would come back truncated. Zapdrop therefore streams such files with
`LIBMTP_GetPartialObject` in 8 MiB windows (Android's `GetPartialObject64`). Smaller files use the faster
single `GetObject`. Phones without 64-bit partial reads get a clear "file too large for this phone" error;
the byte-count check would catch any truncation regardless.

## D13 — Drag-to-Finder through a staging folder
Finder drags need file promises; a multi-gigabyte MTP read can take minutes and blocks the single device channel.
v1 first shipped without drags. Now a drag promises the file, and on drop Zapdrop runs an ordinary transfer job
(visible in the Transfers panel, same sanitising, partial files and verification) into a private staging folder
under Caches, then hands the finished file or folder to Finder, which copies it into place. The cost is a second
local write; staging is cleared at launch. Choosing a destination remains the better path for very large copies.
