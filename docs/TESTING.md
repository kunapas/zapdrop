# Testing

```sh
swift test                                   # everything (macOS or Linux)
FERRY_MOCK_ONLY=1 swift test                 # without libmtp installed
FERRY_LARGE_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter testRealFileLargerThan4GB
FERRY_STRESS_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter FerryStressTests   # stress suite, see below
```
On Linux, install `libmtp-dev libusb-1.0-0-dev`. Set `FERRY_DEPS_PREFIX` to test against a specific libmtp build.
On macOS the tests need full Xcode (the Command Line Tools have no XCTest). Without Xcode, run them in the same
container CI uses, from a copy of the source outside any network share:
```sh
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble bash -c \
  'apt-get update -qq && apt-get install -y -qq libmtp-dev libusb-1.0-0-dev pkg-config && swift test --parallel --scratch-path /tmp/build'
```

## What’s covered (91 automated tests, plus 5 opt-in stress tests)

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
| Browser navigation, cache, sorting, filtering, search, hidden files, selection, disconnect while browsing, large folders filling in piece by piece, leaving a folder stops reading it | `DirectoryBrowserTests` |
| Device states: locked→ready, charging-only, busy with holder name, authorisation, disconnect/reconnect, multiple phones, eject (stays ejected until Connect or replug, refused while copying) | `DeviceMonitorTests` |
| Duplicate prompt round-trip, cancel during prompt, retry | `TransferQueueTests` |
| Settings persistence, destination memory and availability, LRU thumbnail cache, thumbnail pausing | `ServicesTests` |
| End-to-end copy through the app model | `AppModelTests` |
| Battery level, storage totals, USB speed | `PhoneDetailsTests` |
| Quick Look copy, space-bar toggle, reuse, size limit, cancelling leaves nothing behind | `PreviewServiceTests` |
| Drag to Finder (file and folder through the transfer queue) | `FinderDragTests` |
| Every space-saving tip and its threshold; tips for the open folder and selecting their files; empty-folder vs. filtered states; filtering keeps the sort order | `SpaceTipsTests`, `FolderTipsTests` |
| 50,000-item folder, 10,000 small files, 6.5 GB with flat memory, random faults + unplugs retried to completion, 400 random connection changes (opt-in) | `StressTests` |

## Stress testing

Do both parts before a release: the automated suite proves the engine under load, the phone session proves the
real USB stack and macOS integration over hours.

### Automated (simulated phone)

```sh
FERRY_STRESS_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter FerryStressTests   # writes ~7 GB to the temp folder
FERRY_STRESS_TESTS=1 FERRY_STRESS_SEED=42 swift test -c release -Xswiftc -enable-testing --filter FerryStressTests
```
Use a release build: in debug, generating the simulated file contents and SHA-256 verification are too slow for
gigabytes. In release the suite takes under a minute after building.

| Test | Checks |
|---|---|
| `testListingFiftyThousandItemFolder` | First rows within 2 s, whole folder within 60 s, correct order, one request at a time |
| `testCopyTenThousandSmallFiles` | Counts, total bytes, 100 random files byte-for-byte, no `.zapdroppart` left |
| `testHugeFilesKeepMemoryFlat` | 4.5 GB + 2 × 1 GB copied and verified; peak memory grows less than 300 MB |
| `testRandomFaultsRetriedUntilEverythingIsCopied` | 400 files, ~15 % failing up to 3 times part-way, random unplugs; Retry Failed until complete, every file identical |
| `testDeviceMonitorSurvivesHundredsOfStateChanges` | Random unplug / charging-only / busy / locked changes; gone and charging-only phones always reported, recovery to ready, no leaked sessions |

The randomised tests print their seed; a failure message includes it so it can be replayed exactly.

### Real phone soak (2+ hours)

1. Build and launch: `Scripts/build-app.sh && open dist/Zapdrop.app`.
2. In a second Terminal window, record resource use every 5 s: `Scripts/stress-monitor.sh 5 soak.csv`.
3. Also stream the log: `log stream --predicate 'process == "Zapdrop"' --level info > soak.log`. Listing speed shows
   as "Listed N items in … ms (… ms per item)".
4. On the phone, have DCIM/Camera with thousands of photos, a video over 4 GB, and a few folders of documents.
5. Then, without restarting Zapdrop:
   - open DCIM/Camera and leave it part-way through reading, several times (it should stop at once);
   - copy the whole DCIM folder to a local disk with **Verify each file after copying** on;
   - copy the >4 GB video; compare `shasum -a 256` with a copy made another way;
   - during a large copy, unplug the cable, reconnect, unlock, and use **Retry Failed** — repeat 5 times;
   - lock the phone mid-copy and note what happens; Retry must finish the job;
   - open Image Capture to grab the phone, then use **Release Phone from macOS Camera Service**;
   - copy the same folder again and exercise Skip / Replace / Keep Both;
   - leave Zapdrop connected and idle for 30 minutes, then browse again.
6. Afterwards: open `soak.csv` in Numbers. `footprint_mb`, `threads` and `open_files` should rise during work and
   fall back when idle; steady growth across the session is a leak. Check no `.zapdroppart` files remain
   (`find <destination> -name '*.zapdroppart'`) and record the run in `DEVICE_TEST_CHECKLIST.md`.

## Results from the build environment (16 Oct 2026)
- Linux, Swift 6.1.3, libmtp 1.1.23 + libusb 1.0.30 built from the pinned commits: 75 tests pass (1 opt-in skipped), zero compiler warnings with strict concurrency checking.
- Large-file test: 4.5 GB copied and verified in 56 s; peak memory 174 MB, the same as an empty test run.
- C shim: no warnings with `-Wall -Wextra -Wpedantic -Wshadow -Wconversion`.
- 18 Oct 2026, Linux container (Swift 6.1.3, `swift:6.1-noble`): 91 tests pass, zero warnings. Stress suite (release,
  seed 20261017) passes in 47 s: 10,000 small files in 6.3 s; 6.5 GB copied and verified in 36 s (run alone: peak memory 27 MB, +1 MB during the copy);
  50,000-item folder shows first rows after 0.01 s and completes in 1.5 s; 62 faulty files + 2 unplugs complete
  after 6 retry rounds, every file identical; 400 random connection changes with no leaked session.
- **Not yet run:** the SwiftUI app and IOKit code (macOS only — built by CI) and anything needing a real phone
  (`DEVICE_TEST_CHECKLIST.md`).
