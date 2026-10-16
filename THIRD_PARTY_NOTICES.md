# Third-party notices

Ferry's own code is under the MIT licence (`LICENSE`). Ferry bundles two libraries, **unmodified** and
**dynamically linked** as separate files inside `Ferry.app/Contents/Frameworks/`:

| Library | Version | Licence | Source |
|---|---|---|---|
| libmtp | 1.1.23 (commit `55fa074240b703adb48c78d31d156879cb9e4959`) | GNU LGPL 2.1 or later | https://github.com/libmtp/libmtp |
| libusb | 1.0.30 (commit `87a55632db62c9bdc58cd31d3ccfa673f1bb017f`) | GNU LGPL 2.1 or later | https://github.com/libusb/libusb |

## Your rights under the LGPL

- The complete corresponding source code for these libraries is available at the links above, at the
  exact commits listed. `Scripts/build-deps.sh` in Ferry's repository shows exactly how they were built.
  On request, the maintainers will also provide the source on a physical medium for at least three years
  after the last release that included them.
- You may replace `libmtp.9.dylib` or `libusb-1.0.0.dylib` inside the app with your own compatible
  build. Re-sign the app afterwards (for example `codesign --force --deep --sign - Ferry.app`) so macOS
  will load it.
- Ferry imposes no terms that forbid modifying these libraries or reverse-engineering Ferry to debug
  such modifications.

The full licence texts ship inside the app at `Ferry.app/Contents/Resources/Licenses/`
(`libmtp-COPYING.txt`, `libusb-COPYING.txt`) and in the DMG's `Licenses` folder.

## Other

No other third-party code is included. SHA-256 (for optional read-back verification) is implemented in
Ferry itself. Apple system frameworks (SwiftUI, AppKit, IOKit, ImageIO) are part of macOS.
