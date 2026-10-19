# Project plan and risks

## Riskiest assumptions (highest first)

1. **Device access isn't blocked by macOS.** `ptpcamerad`, Photos, Image Capture, Smart Switch or Android File
   Transfer may hold the phone. Mitigation: detect exclusive access, explain, offer user-initiated release.
   _Needs real-device testing on macOS 14, 15 and 26._
2. **>4 GB files download correctly** on real phones through libmtp. Engine is 64-bit throughout and tested
   with a 4.5 GB mock stream; the USB/MTP side must be checked on hardware.
3. **libmtp behaves on current Samsung/Pixel/Xiaomi firmware** in uncached mode. Checklist in
   `DEVICE_TEST_CHECKLIST.md`.
4. **Universal dylib bundling + notarisation** of LGPL libraries works as scripted. Verified only in CI / on a Mac.
5. **SwiftUI code compiles** — it can only be compiled on macOS; it is kept thin, was reviewed independently
   against the macOS 14 SDK, and is built in CI.
6. **libmtp leaves the USB handle open on some failed opens** (upstream behaviour in 1.1.23, found in review).
   Mitigation: Zapdrop checks for a competing owner before asking libmtp to open, so the common "busy" case
   never reaches those paths; a leftover claim is cleared by reconnecting the phone. Worth an upstream patch.

## Phases

| Phase | Scope | Verified by |
|---|---|---|
| 1 | Research, decisions, package scaffold, core models/protocols, mock backend | Linux build + tests |
| 2 | Browser view models (sort, filter, selection, navigation, destination) + SwiftUI views | View-model tests on Linux; UI on macOS |
| 3 | Streaming engine: plan, preflight, partial files, atomic rename, duplicates, cancel, retry, verify | Unit tests incl. 4.5 GB mock stream |
| 4 | C shim + libmtp backend, discovery, storage, streaming, thumbnails | Compiles + smoke test against real libmtp on Linux; device tests on Mac |
| 5 | Thumbnails, accessibility, errors, docs, packaging, CI | macOS CI + manual checklist |

## Post-MVP (deliberately not in v1)

- Copy Mac → phone, delete/rename on phone (only after read-only flows are proven).
- Drag from Zapdrop to Finder (needs file promises that survive multi-minute MTP reads; not reliable enough yet).
- Video thumbnails, resuming partially downloaded files (`GetPartialObject64`), parallel devices.
- Swap to mtp-rs or a native Swift MTP stack if libmtp proves limiting.
