# Releasing: signing, notarisation and the DMG

Ferry ships **outside the Mac App Store**, signed with a Developer ID, Hardened Runtime on,
**not sandboxed** (see `DECISIONS.md` D5), notarised by Apple, in a DMG.

## One-time setup
1. Apple Developer Program membership (needed for a Developer ID certificate and notarisation).
2. Create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates)
   and check it's in your keychain: `security find-identity -v -p codesigning`.
3. Store notarisation credentials in the keychain (uses an app-specific password from appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials ferry-notary --apple-id you@example.com --team-id TEAMID
   ```
4. Set your own bundle identifier in `Scripts/config.sh` (`BUNDLE_ID`) and in the Xcode project.

## Build a release
```sh
export FERRY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
Scripts/build-deps.sh                       # pinned libmtp + libusb, universal
swift test                                  # must pass
Scripts/build-app.sh                        # builds, embeds and signs dylibs, signs app with Hardened Runtime
Scripts/make-dmg.sh                         # dist/Ferry-<version>.dmg (+ .sha256), signed
FERRY_NOTARY_PROFILE=ferry-notary Scripts/notarize.sh   # notarise, staple, Gatekeeper check
```
What gets signed, inside out: `libusb-1.0.0.dylib`, `libmtp.9.dylib` (in `Contents/Frameworks`), then the
app (with `App/Support/Ferry.entitlements`), then the DMG. Never use `codesign --deep` for release signing.

Automated alternative: `.github/workflows/release.yml` does the same on a `v*` tag when the signing
secrets are configured, and drafts a GitHub release.

## Release checklist
- [ ] Version bumped in `Scripts/config.sh` (`APP_VERSION`, `APP_BUILD`) and the Xcode project (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`).
- [ ] Dependency pins in `Scripts/config.sh` reviewed; `THIRD_PARTY_NOTICES.md` matches them.
- [ ] `swift test` passes on macOS; CI green on `main`.
- [ ] Large-file test run: `FERRY_LARGE_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter testRealFileLargerThan4GB`.
- [ ] `DEVICE_TEST_CHECKLIST.md` completed on at least one Samsung, one Pixel and one other brand; results recorded.
- [ ] Tested on Apple Silicon **and** Intel (or Rosetta-free x86_64 check: `lipo -info` shows both slices for app and dylibs).
- [ ] Tested on the oldest supported macOS (14) and the newest.
- [ ] `codesign --verify --deep --strict --verbose=2 dist/Ferry.app` and `spctl -a -vv dist/Ferry.app` pass.
- [ ] `otool -L dist/Ferry.app/Contents/MacOS/Ferry` shows `@rpath/libmtp.9.dylib`; no `/opt/homebrew` or `Vendor/` paths.
- [ ] No network use: `nettop -p Ferry` (or Little Snitch) shows no connections during a full session.
- [ ] DMG opens on a clean Mac (no Homebrew), app launches without Gatekeeper warnings.
- [ ] Licences present: `Ferry.app/Contents/Resources/Licenses/` contains LICENSE, notices, both COPYING files and SOURCES.txt.
- [ ] Release notes list known limitations; SHA-256 of the DMG published with it.

## About the App Sandbox
`App/Support/Ferry-Sandboxed.entitlements` exists for experiments. libusb can work in the sandbox with
`com.apple.security.device.usb`, but a sandboxed app cannot end `ptpcamerad`, which is the most common
reason a phone won't connect. Do not ship a sandboxed build until it is tested on real devices and the
"phone is busy" guidance is adjusted to tell users to run `killall ptpcamerad` themselves.
