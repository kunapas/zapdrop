# Manual device test checklist

Automated tests cover the engine with a simulated phone. This checklist covers what only real hardware can.
Copy the results table into the release notes.

## Devices to cover (aim for at least 4 rows per release)
| Brand | Why | Suggested models |
|---|---|---|
| Samsung | Most common; "Allow access" prompt; known MTP quirks | Galaxy S series, A series |
| Google Pixel | Reference Android, USB 3, 64-bit partial reads | Pixel 7–10 |
| Xiaomi / Redmi / POCO | MIUI/HyperOS USB-mode quirks | any recent |
| OnePlus / OPPO / realme | ColorOS MTP | any recent |
| Motorola / Nokia / Fairphone | Near-stock Android | any |
| Older device | Android 8–10, USB 2 | anything available |

Also vary: Android 10, 12, 14, 15/16; Apple Silicon and Intel Macs; macOS 14, 15 and 26; USB-C to C and
USB-A to C cables; a hub.

## Before you start
- Fresh build: `Scripts/build-app.sh`, launch `dist/Ferry.app`.
- Open Console.app filtered to `Ferry` to capture logs.
- Prepare on the phone: a folder with 1,000+ small photos, a video over 4 GB (e.g. 30+ minutes of 4K),
  a file with a long name (200+ characters), names differing only by case, and an empty folder.

## Connection states
- [ ] No phone connected → "Connect your Android phone" with steps.
- [ ] Connect with a **charge-only cable** → still "Connect…" (nothing is detected over a power-only cable).
- [ ] Data cable, phone in **Charging only / No data transfer** → "is only charging".
- [ ] Phone **locked** while switching to File transfer → "Unlock …"; unlocking → browser appears within ~3 s.
- [ ] Samsung "Allow access to phone data?" prompt → waiting state; tap Allow → ready.
- [ ] Open **Image Capture** first so it grabs the phone → "in use by another app" naming it; quitting it + Try Again → ready.
- [ ] `ptpcamerad` holding the phone → **Release Phone from macOS Camera Service** → ready.
- [ ] Two phones connected → both listed; switching between them works.

## Browsing
- [ ] Storage list shows Internal storage (and SD card if present) with sensible free/total space.
- [ ] Open DCIM/Camera with 1,000+ items: UI stays responsive; loading indicator shows.
- [ ] Sort by name, date, size, kind; filter Photos/Videos/Audio/Documents; search.
- [ ] Thumbnails appear for JPEGs in list and grid views; videos show an icon.
- [ ] Back (⌘↑), breadcrumb clicks, double-click/Return to open folders.
- [ ] VoiceOver (⌘F5): rows read "name, kind, size"; buttons are labelled; the transfer progress is announced.
- [ ] Keyboard only: navigate the table, select, ⇧⌘C copies.
- [ ] Light and dark mode both readable.

## Copying
- [ ] Copy one photo → identical bytes (`shasum -a 256` vs. a copy made another way), modification date preserved.
- [ ] Copy a folder tree with empty folders → structure recreated.
- [ ] Copy the **> 4 GB video** → completes; size matches exactly; progress and ETA sensible throughout; Activity Monitor shows Ferry's memory flat.
- [ ] Copy 1,000+ small files → completes; count matches; speed reasonable.
- [ ] Case-clash names → second saved as `name (1).ext`; listed under "Saved under a different name".
- [ ] Duplicates: copy the same folder twice → prompt appears; test Skip, Replace, Keep Both, and "apply to all".
- [ ] Verify-after-copy on → files marked verified; noticeably slower but correct.
- [ ] Destination on an external APFS disk and on an exFAT disk.

## Failure handling
- [ ] **Cancel** mid-file → no `.ferrypart` left; finished files kept; summary lists the rest as not copied.
- [ ] **Unplug** mid-transfer → "Phone disconnected"; no partial file; reconnect → **Retry Failed** copies only the remainder.
- [ ] **Lock the phone** mid-transfer → note the behaviour (varies by brand); Retry recovers.
- [ ] **Delete a file on the phone** that's queued → reported as "no longer on the phone"; others continue.
- [ ] **Eject the destination disk** mid-transfer → "Destination not available"; Retry after reconnecting works.
- [ ] **Nearly full destination** (use a small disk image: `hdiutil create -size 200m -fs APFS -volname Tiny tiny.dmg`) → refused before starting, or stops cleanly mid-way; nothing corrupt.
- [ ] Destination folder without write permission → "Ferry can't write here".

## Results
| Date | Mac / macOS | Phone / Android | Build | Pass | Notes / failures (with Console excerpt) |
|---|---|---|---|---|---|
| | | | | | |
