# Testing

```sh
swift test                                   # everything (macOS or Linux)
FERRY_MOCK_ONLY=1 swift test                 # without libmtp installed
FERRY_LARGE_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter testRealFileLargerThan4GB
```
On Linux, install `libmtp-dev libusb-1.0-0-dev`. Set `FERRY_DEPS_PREFIX` to test against a specific libmtp build.

## What's covered (75 automated tests)

| Area | Tests |
|---|---|
| Sizes over 4 GB, saturating 64-bit maths, progress fractions, byte/time formatting, speed & ETA | `ByteMathTests` |
| Path traversal, separators, control & bidi characters, NFC, 255-byte limit, emoji, numbered variants, case/Unicode clash keys, `SafePath` | `FileNameSanitizerTests` |
| SHA-256 against NIST vectors, streaming = one-shot | `SHA256Tests` |
| Every error has friendly text without raw detail; errno mapping | `ErrorMapperTests` |
| Mock phone: storages, locked, busy, charging-only, authorisation, 6 GiB virtual stream in bounded chunks, disconnect, thumbnails | `MockBackendTests` |
| Recursive planning, folder loops, copy + content + dates, empty folders, verification, duplicates (skip/replace/keep both/ask/apply-to-all/cancel), cancel mid-file, task cancellation, failed file + retry only it, source removed, disconnect + retry on renumbered phone, disk-space preflight, disk full mid-way, symlink in destination, malicious names, size mismatch, one-request-at-a-time | `TransferEngineTests` |
| Real 4.5 GB file to disk with verification and a spot check past 4 GiB (opt-in) | `testRealFileLargerThan4GB` |
| libmtp/libusb link, discovery without phones, USB ID round-trip, opening a missing device, object conversion | `LibMTPBackendTests` |
| Browser navigation, cache, sorting, filtering, search, hidden files, selection, disconnect while browsing | `DirectoryBrowserTests` |
| Device states: locked→ready, charging-only, busy with holder name, authorisation, disconnect/reconnect, multiple phones | `DeviceMonitorTests` |
| Duplicate prompt round-trip, cancel during prompt, retry | `TransferQueueTests` |
| Settings persistence, destination memory and availability, LRU thumbnail cache, thumbnail pausing | `ServicesTests` |
| End-to-end copy through the app model | `AppModelTests` |

## Results from the build environment (16 Oct 2026)
- Linux, Swift 6.1.3, libmtp 1.1.23 + libusb 1.0.30 built from the pinned commits: 75 tests pass (1 opt-in skipped), zero compiler warnings with strict concurrency checking.
- Large-file test: 4.5 GB copied and verified in 56 s; peak memory 174 MB, the same as an empty test run.
- C shim: no warnings with `-Wall -Wextra -Wpedantic -Wshadow -Wconversion`.
- **Not yet run:** the SwiftUI app and IOKit code (macOS only — built by CI) and anything needing a real phone
  (`DEVICE_TEST_CHECKLIST.md`).
