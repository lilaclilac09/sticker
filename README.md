# Stickerize

Turn any photo or image into stickers, then use them everywhere:

- **Messages, and the system Stickers drawer in every app.** The iMessage extension opts into the *media* presentation
  context, so iOS also lists it in the emoji keyboard's Stickers section (any app), FaceTime and Markup.
- **WhatsApp and Telegram packs.** Pick 3–30 stickers (WhatsApp) or up to 120 (Telegram) and add them through each app's
  official import API. They then live in that app's own sticker picker.
- **Any other app** (Signal, Slack, Mail…): the Stickerize keyboard copies a sticker so you can paste it. It also works as a
  plain typing keyboard.
- **Share, copy, drag, Save to Photos** from the app. From Photos you can add a sticker to the iPhone's own sticker library
  with *Add Sticker*; no API exists for apps to do that directly.

Stickers come from Photos (multi-select), Files (any format ImageIO reads, plus page 1 of a PDF), the pasteboard,
drag and drop, or the share sheet ("Stickerize"). The editor lifts every foreground subject with Vision. You choose
which subjects to keep, and you can crop to the subject, add a white outline, and set a name and emoji. Every saved
sticker is normalized to what `MSSticker.h` requires: PNG, each side 300–618 px, ≤ 500 KB.

`stickerize`, the original macOS command-line tool, is rebuilt on the same library (see below).

## Layout

Everything lives in `stickerize/`:

| Path | What |
| --- | --- |
| `Stickerize.xcodeproj` | App + 3 extensions + UI tests. Folders are file-system synchronized: new files are picked up automatically. |
| `Config/Base.xcconfig` | Bundle ID prefix, App Group, team. Per-target Info.plists and the shared entitlements file. |
| `App/` | SwiftUI container app: library, import, sticker page, WhatsApp/Telegram export, setup guide. |
| `Shared/` | The sticker editor and import helpers, compiled into the app and the Share extension. |
| `MessagesExtension/` | iMessage app: `MSStickerBrowserViewController` over the shared library. |
| `KeyboardExtension/` | Sticker keyboard (tap to copy) plus a QWERTY/123 typing layout. |
| `ShareExtension/` | "Stickerize" in the share sheet, same editor as the app. |
| `StickerizeKit/` | Swift package. `StickerizeKit`: storage, decoding, normalization (no Vision, safe for every extension). `StickerLift`: Vision subject lifting and outlines. `StickerExport`: WhatsApp/Telegram payloads (libwebp). `stickerize`: the CLI. Plus tests. |
| `samples/` | Test photos used by the package tests and the CLI examples. |
| `scripts/` | `make-icons.swift` (draws every icon), `generate-xcodeproj.py` (how the project file was made). |

The package isn't called `StickerKit` because Apple ships an empty system module with that name in the device and
macOS SDKs (but not the simulator SDK). A shadowing module would fail differently on device and in the simulator.

## Build and run

Requires Xcode 27 (iOS 27 SDK); the app runs on iOS 17 and later. If Xcode isn't your selected developer directory,
prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
open stickerize/Stickerize.xcodeproj
```

**Simulator:** select the *Stickerize* scheme and run. No team is needed. Don't build simulator copies with
`CODE_SIGNING_ALLOWED=NO`: that drops the entitlements, the App Group stops working, and the extensions can't see the
library (the app then shows a warning).

**Device:** put your team in `stickerize/Config/Local.xcconfig` (git-ignored), and change the bundle ID prefix if
`ai.qokka.stickerize` isn't yours:

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.example.stickerize
```

The App Group is derived from the prefix (`group.<prefix>`), written into every target's entitlements and Info.plist,
and registered by automatic signing (`REGISTER_APP_GROUPS`). Nothing else needs editing.

**Tests:**

```bash
cd stickerize/StickerizeKit && swift test
```

58 tests cover decoding, orientation, normalization limits, the store, Vision lifting on the samples, outlines and the
WebP/pack payloads. Vision tests run on the Mac only: Vision's instance masks don't run in the iOS Simulator.
The scheme's Test action runs the same package tests plus the UI tests in the simulator.

## Turning it on

- **Messages / Stickers drawer:** nothing to set up. Open the emoji keyboard and tap Stickers, or in Messages tap
  **+ › Stickers**.
- **Keyboard:** Settings › General › Keyboard › Keyboards › Add New Keyboard › **Stickerize**. Then tap Stickerize and
  turn on **Allow Full Access**, which copying stickers needs. Without it, the keyboard still shows your stickers and
  types normally. The keyboard has no network code.
- **WhatsApp / Telegram:** in the app, tap Select, pick stickers, then Add to… › WhatsApp or Telegram.

## The command-line tool

```bash
cd stickerize/StickerizeKit
swift run stickerize ../samples/test3.jpg --list
swift run stickerize ../samples/test3.jpg --include 1 --outline 12 --output person.png
```

Run `stickerize --help` for the options. The output meets the iMessage limits unless you pass `--full-size`. Logs go
to stderr and the output path to stdout. Exit codes: 1 error, 2 usage, 3 no subject found.

## Known limits

- In the simulator, background removal is unavailable (the editor says so and uses the whole image). Test it on a device.
- Declaring the media context means the iMessage app lives in the Stickers drawer rather than the Messages app list.
- WhatsApp and Telegram import, the keyboard's Full Access behaviour and how other apps treat pasted stickers have been
  checked against each project's source and docs, not on a device. See [`stickerize/REVIEW.md`](stickerize/REVIEW.md) for what was verified and how.
