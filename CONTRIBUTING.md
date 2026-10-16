# Contributing to Ferry

Thanks for helping. Ferry aims to be small, reliable, private and free forever.

## Ground rules
- **No network code, telemetry, analytics, ads, accounts, licence checks or usage limits.** PRs adding any
  of these will be closed.
- **Read-only towards the phone** until copying is proven on many devices. Deleting or changing phone files
  needs a design discussion first (open an issue).
- **One MTP request at a time.** All libmtp calls go through `DeviceQueue.shared`. Don't add parallel device I/O.
- **Only `Sources/CFerryMTP` includes libmtp headers; only `Sources/FerryLibMTP` imports it.**
- New dependencies need a strong reason and a licence compatible with MIT + LGPL dynamic linking.

## Getting started
See README → Building. Most work needs no phone: run the app with `--mock`, and write tests against
`FerryMock` (it can simulate locked phones, busy devices, disconnects, faults on specific files, and files of
any size without using memory).

## Before opening a pull request
- `swift test` passes; add tests for new behaviour (failure paths especially).
- No new compiler warnings (strict concurrency checking is on).
- User-facing errors go through `ErrorMapper`. Never show raw library messages.
- File names in logs are passed as the `privateValue` argument so they're redacted.
- Device-specific changes: say which phones you tested with, using `docs/DEVICE_TEST_CHECKLIST.md`.
- Keep commits small and focused. Explain *why* in the description.

## Reporting a phone that doesn't work
Open an issue with: phone brand/model, Android version, Mac model, macOS version, what Ferry showed, and
Console.app messages filtered to `Ferry` (file names appear as `<private>`).

## Security and privacy issues
Please report privately to the maintainers (GitHub Security Advisories on the repository) rather than in a
public issue. Include steps to reproduce.

## Licence
By contributing you agree your contribution is licensed under the MIT licence.
