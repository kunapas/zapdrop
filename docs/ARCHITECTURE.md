# Architecture

## Layers

```
┌──────────────────────────────── App (macOS only, SwiftUI) ─────────────────────────────────┐
│ FerryApp: windows, Table/grid browser, transfer panel, duplicate sheet, settings,           │
│ ThumbnailRenderer (ImageIO), ExclusiveAccessInspector (IOKit), CameraDaemonReleaser         │
└───────────────────────────────▲─────────────────────────────────────────────────────────────┘
                                │ observes (@Observable, main actor)
┌───────────────────────────────┴──────── FerryAppModel (cross-platform, unit-tested) ─────────┐
│ DeviceMonitor · DirectoryBrowserViewModel · TransferQueueViewModel · ThumbnailService       │
│ LocalDestinationService · DuplicatePromptCoordinator                                         │
└───────────────────────────────▲─────────────────────────────────────────────────────────────┘
                                │ async/await
┌───────────────────────────────┴──────────── FerryCore (cross-platform, unit-tested) ─────────┐
│ Models (64-bit sizes) · DeviceBackend / DeviceSession protocols · ErrorMapper · Logger       │
│ TransferPlanner · TransferOperation · TransferCoordinator · DuplicateResolutionService       │
│ LocalFileWriter (partial file, fsync, atomic rename) · FileNameSanitizer · SafePath          │
│ SpeedEstimator · ByteFormatter · SHA256 · VolumeSpaceProvider                               │
└──────────────▲───────────────────────────────────────────────────▲───────────────────────────┘
               │ implements DeviceBackend                          │ implements DeviceBackend
┌──────────────┴───────────── FerryLibMTP ───────────┐   ┌─────────┴──────── FerryMock ───────────┐
│ LibMTPBackend · LibMTPSession                       │   │ Scripted phones, storages, folder trees │
│ DeviceQueue (one serial queue for every libmtp call)│   │ Virtual files of any size (no memory)  │
└──────────────▲─────────────────────────────────────┘   │ Fault injection: disconnect, busy, lock │
┌──────────────┴───── CFerryMTP (C shim, ~300 lines) ─┐   └─────────────────────────────────────────┘
│ ferry_mtp_* functions; only file including libmtp.h │
└──────────────▲─────────────────────────────────────┘
          libmtp.dylib → libusb-1.0.dylib  (bundled in Zapdrop.app/Contents/Frameworks)
```

Rule: only `CFerryMTP` includes libmtp headers; only `FerryLibMTP` imports `CFerryMTP`. Swap the backend
without touching anything above it.

## Directory layout

```
Package.swift                 Swift package (source of truth)
Sources/FerryCore/            engine, models, protocols
Sources/FerryMock/            mock phone backend
Sources/CFerryMTP/            C shim over libmtp/libusb
Sources/FerryLibMTP/          real backend
Sources/FerryAppModel/        view models and services (no SwiftUI)
App/Ferry/                    SwiftUI app sources (macOS only)
App/Support/                  Info.plist, entitlements
App/Ferry.xcodeproj           Xcode shell project that uses the package
Tests/…                       unit tests (run on Linux and macOS)
Scripts/                      build-deps, build-app, make-dmg, notarize
docs/                         this folder
```

## Device states

`DeviceConnectionState`: `noDevice`, `chargingOnly`, `awaitingAuthorization`, `locked`, `busy(holder)`,
`ready`, `unsupported`, `disconnected`. How each is detected:

| State | Signal |
|---|---|
| noDevice | No USB device with an MTP interface or known phone vendor ID |
| chargingOnly | Known phone vendor ID, no MTP/PTP interface |
| awaitingAuthorization | MTP interface present, opening fails for a short while after it appears (phone still switching mode / prompting) |
| busy | Opening fails because another process holds the interface (exclusive access) |
| locked | Session opens but the phone reports no storage (locked, or "Allow access" not tapped) |
| ready | Session open, at least one storage |
| disconnected | Device vanished while a session was open (browsing or transferring) |

## Transfer pipeline

1. **Plan** — walk selected folders lazily on the device queue; build a flat list of folders and files with
   sanitised relative paths; detect case/Unicode name clashes; sum 64-bit sizes.
2. **Preflight** — check free space on the destination volume (excluding files that already exist).
3. **Copy, one file at a time** — create folders safely (no following links), resolve duplicates
   (policy or ask), stream into `<name>.zapdroppart` in bounded chunks, `fsync`, check byte count,
   set modification date, optional read-back verification, atomic rename.
4. **Finish** — per-item status (`completed`, `skipped`, `failed`, `cancelled`), job status
   (`completed`, `partiallyCompleted`, `failed`, `cancelled`), summary.
5. **Retry** — re-runs only failed/cancelled items of the same job.

Job states: `queued → preparing → running → completed | partiallyCompleted | failed | cancelled`.
One job runs at a time per device (the coordinator queues the rest).

Progress is kept in a lock-protected snapshot updated by the copy loop; the UI samples it ~8 times a second,
so very fast USB callbacks never flood the main thread.
