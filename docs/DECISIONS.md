# Key technical decisions

Short records of decisions that shape the code. Newest last.

## D1 — Name: "Ferry" (provisional)
"OpenMTP Mac" is too close to the existing OpenMTP project. "Ferry" is short, describes moving things
across, and avoids the "Android" trademark in the product name ("for Android phones" is used descriptively only).
No formal trademark search has been done. The name lives in `App/Ferry/Info.plist`, `Package.swift` and
`Scripts/config.sh` only.

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
Each file is written to `<name>.ferrypart` in the destination folder (same volume, so `rename` is atomic),
flushed with `fsync`, size-checked, dated, then renamed. If renaming would overwrite something the user did
not agree to replace, it fails rather than clobbering (`renamex_np(RENAME_EXCL)` on macOS). Partial files are
deleted on cancel or failure; any left behind by a crash are clearly named.

## D8 — Integrity: byte counts always, read-back verification optional
Android does not expose file hashes over MTP. Ferry always checks that bytes written == size the phone reported.
Optional "Verify after copying" computes SHA-256 while receiving, then re-reads the written file and compares.
This proves the Mac's copy is intact on disk — not that the phone's copy was intact. The UI says exactly that.

## D9 — Device discovery by polling libusb, not opening devices
Every 1.5 s Ferry lists USB devices (cheap, does not open them or disturb transfers). Only when the set changes does it
ask libmtp to probe. This avoids racing `ptpcamerad`, and lets Ferry spot a phone in "charging only" mode
(known phone vendor, no MTP interface).

## D10 — Licence: MIT for Ferry's own code
Permissive, compatible with dynamically linked LGPL libraries.

## D11 — No dependencies beyond libmtp/libusb
SHA-256 is implemented in-repo (validated against NIST vectors) rather than adding swift-crypto, because only
streaming hashing for read-back verification is needed. On macOS CryptoKit could replace it later.
