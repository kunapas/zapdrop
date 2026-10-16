# Troubleshooting

## The phone doesn't appear at all
- **Cable.** Many cables only charge. Try one you know carries data (the one that came with the phone is best).
- **Port / adapter.** Plug directly into the Mac, not through a monitor or unpowered hub. Try another port.
- **Unlock the phone.** Keep it unlocked while connecting.

## "Phone is only charging"
The phone is connected but file sharing is off.
1. Swipe down from the top of the phone and tap the **USB** notification ("Charging this device via USB").
2. Choose **File transfer** (may be called "File Transfer / Android Auto", "Transfer files" or "MTP").
3. If there's no notification: Settings → Connected devices → USB (wording varies by brand).

## "Unlock your phone"
Android hides storage until it's unlocked. Some phones (Samsung, Xiaomi) also ask **Allow access to phone
data?** — tap **Allow**. Ferry checks again automatically every couple of seconds.

## "Phone is in use by another app"
Only one program can talk to the phone at a time. Quit any of these, then click **Try Again**:
Image Capture, Photos, Preview (Import), Android File Transfer, Samsung Smart Switch, OpenMTP, MacDroid,
Handshaker, Kies.

Still blocked? macOS's background camera service (`ptpcamerad`) often grabs phones automatically.
Click **Release Phone from macOS Camera Service**. It ends that process for your user account (macOS
restarts it when needed), and Ferry immediately tries again. Equivalent Terminal command:
`killall ptpcamerad`. If Photos is set to open when a device connects, turn that off in Image Capture
(select the phone → "Connecting this iPhone/device opens: No application").

## Transfer stopped: "Phone disconnected"
Files already finished are complete and kept; the unfinished file was deleted. Reconnect, unlock,
make sure the USB mode is still **File transfer**, then click **Retry Failed**. Ferry finds the remaining
files again even if the phone renumbered them.
Tip: some phones drop the connection when the screen locks during long copies. Keep it awake (or increase
the screen timeout) for big transfers.

## "Not enough space on your Mac"
Ferry checks free space before starting (plus a 100 MB safety margin) and before each file. Free up space
or choose a folder on another disk, then **Retry Failed**.

## "File too large for this phone's USB mode"
Files of 4 GB or more need the phone to support 64-bit partial reads over MTP. Most Android 7+ phones do;
some older or unusual devices don't. Copy that file another way (memory-card reader, network share).
Also check the destination disk: **FAT32** drives can't store files of 4 GB or more — use APFS or exFAT.

## Some files were renamed
- Two phone files whose names differ only by capital letters (`IMG.jpg` and `img.jpg`) can't coexist in
  a normal Mac folder; the second becomes `img (1).jpg`.
- Characters macOS can't use in a name (`/`, `:`, control characters, hidden direction-reversing characters)
  are replaced with `_`.
The transfer **Details** list shows every renamed file and its new name.

## Leftover `.ferrypart` files
These are incomplete copies. Ferry deletes them on cancel or failure; one can be left behind only if the
Mac lost power or Ferry was force-quit mid-file. They're safe to delete.

## Copies are slow
MTP speed depends mostly on the phone. USB 2 phones typically manage 20–40 MB/s; USB 3 phones more.
Thousands of tiny files are slower than a few big ones (each file costs several round-trips).
Use a USB 3 port and cable for USB 3 phones.

## Collecting diagnostics for a bug report
1. Open Console.app, search for `Ferry`, reproduce the problem, and copy the messages. File names show as
   `<private>`; that's intentional.
2. Include: Mac model, macOS version, phone brand/model, Android version, and the exact message Ferry showed.
