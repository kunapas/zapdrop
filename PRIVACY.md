# Privacy statement

**Short version: Zapdrop never sends anything anywhere.**

- **No network.** Zapdrop makes no network requests at all — no update checks, analytics, crash reporting,
  telemetry, licence checks or cloud features. Zapdrop has no networking code. The optional "Buy Me a Coffee"
  menu item only opens the link in your web browser when you choose it.
- **No accounts.** Nothing to sign up for or log in to.
- **Your files stay yours.** File contents, names and metadata go from your phone to the folder you
  choose on your Mac, and nowhere else.
- **What Zapdrop remembers** (stored in macOS preferences on your Mac only):
  the last destination folder, the view mode (list or thumbnails), and your settings
  (duplicate handling, verification, date preservation, hidden files).
- **Logs.** Zapdrop writes diagnostic messages to the macOS system log on your Mac. File names are marked
  private, so macOS hides them unless you explicitly enable private logging on your own machine.
  Logs are never sent to the developers.
- **Thumbnails** are kept in memory only while Zapdrop is open, and are never written to disk.
- **Previews and drags.** A file you preview with Quick Look or drag into Finder is first copied to Zapdrop's cache
  folder on your Mac (`~/Library/Caches`). Those copies are deleted when the phone is disconnected and when Zapdrop
  quits.
- **Permissions.** Zapdrop needs access to USB devices (to talk to your phone) and to the folder you
  choose. It does not ask for contacts, location, camera, microphone or any other permission.
- **Freeing the phone.** When macOS's camera service grabs the phone, Zapdrop ends that background process for your
  own user account so it can connect (macOS restarts it when needed); you can turn this off in Settings. Apps such
  as Photos are only quit when you click **Free Up Phone & Connect** or choose to let Zapdrop do it automatically.

If you find behaviour that contradicts this statement, please report it as a security issue
(see `CONTRIBUTING.md`).
