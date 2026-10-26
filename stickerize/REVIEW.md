# Review: from `stickerize` CLI to the Stickerize iOS app

The starting point was a single-file macOS command-line tool (not included in this repository). It used Vision's foreground instance mask to
lift subjects into a transparent PNG. Kept: class-agnostic instance picking, the reason the tool exists, and the
lifting approach. Everything else was rebuilt as a shared Swift package used by an iOS app, three extensions and a new CLI.

All measurements below were taken with macOS 27.2, Xcode 27.2, and the iOS 27.2 SDK and simulator.

## 1. Findings on the original tool

Each was reproduced against the original tool's binary before being fixed.

| # | Finding | Verdict | Fix | Covered by |
| --- | --- | --- | --- | --- |
| 1 | `--list` boxes were in Vision's mask grid, not image pixels | **Confirmed.** The label mask is always 512×512 `L008`, whatever the aspect ratio. On the 960×641 `test3.jpg`, instance 1 listed as w:51 h:248, but `--crop` wrote 96×311. | Boxes are scaled per axis (`SubjectAnalysis`). The new `--list` gives 96×311. | `testBoundingBoxesAreInImagePixels` |
| 2 | Pixel format guessed from `bytesPerRow / width`; `UInt8(id)` could trap | **Partly.** On synthetic masks ≤ 32 px wide (row padding 64) the guess reads Float32 and returns nothing, or traps in `-Onone`. Real Vision masks are always 512 wide, so today's output was right. `UInt8(id)` can't trap: ids come from an 8-bit mask. | `LabelMap` reads `CVPixelBufferGetPixelFormatType`, honours `bytesPerRow`, and handles OneComponent8 and Float32. | `testHitTesting…`, `testOverlay…` |
| 3 | EXIF orientation ignored | **Confirmed.** An orientation-6 JPEG came out sideways, and detection itself changed (an instance grew from 2.3% to 3.4%). | `ImageLoader` decodes through `CGImageSourceCreateThumbnailAtIndex` with `…WithTransform` and `…FromImageAlways` (`IfAbsent` returns 160 px embedded thumbnails). Vision gets the upright image. | `testAppliesEXIFOrientation`, `testRotatedInputIsLiftedUpright`, simulator import of `rotated6.jpg` |
| 4 | Top-level `try` crashes instead of erroring | **Confirmed, with corrections.** An unwritable `--output` traps (exit 133). The suggested repro (`handler.perform` throwing) never happened. The throws users can actually hit are `generateMaskedImage` with an empty selection plus `--crop`, and any side over 16384 px. | Every error is caught. Exit codes: 1 error, 2 usage, 3 no subject. Empty selections are rejected. Input is capped at 4096 px working size. | CLI runs below |
| 5 | Output not normalized (744 KB, 1280 px) | **Confirmed, and the limit was understated.** `MSSticker.h` (iOS 27.2 SDK) also requires **at least 300×300**, and `MSSticker(contentsOfFileURL:)` validates nothing (it accepted 100×100, 1.3 MB and missing files). The `--scale` quality claim is **refuted on macOS**: `CIContext` downsamples at high quality by default on macOS, but not on iOS, so a port would have regressed. | `StickerEncoder` scales toward 618 px (upscaling at most 3×), pads each side to ≥ 300 px on transparent canvas, and shrinks until ≤ 500,000 bytes. Opaque images are stored without alpha (10–15% smaller). | `testEveryStickerMeetsMSStickerLimits` and 7 more; 9 simulator imports all in spec |
| 6 | Small issues (mid-file import, no-op guard, default name, no padding, logs on stdout) | **Confirmed.** Stdout logging was worse than cosmetic: piped output was block-buffered, so a crash lost every log line. | Logs go to stderr, the output path to stdout. Output name is `<name>-sticker.png`. Outline and padding added. Options in any order, plus `--help`. | |

The verification pass found six more problems:

- `--include ","` or `""` parsed as an empty selection. It wrote a blank full-size PNG with exit 0, or crashed with `--crop`. Now a usage error.
- `--scale 1e-9` crashed; `1e-4` silently wrote a 1×1 PNG. Replaced by `--max-size`.
- `--list` also wrote, or overwrote, `<input>-sticker.png`. It is now list-only.
- `croppedToInstancesExtent` cut off the soft alpha halo below 128. The new crop trims by alpha (threshold 8) on the full cut-out.
- No downsampling: an 8000 px input peaked at **1.39 GB**. The new CLI works at ≤ 4096 px: a 9000×6000 input peaks at 429 MB, and `--list` still reports original pixels.
- Not a bug: Vision returns 8-bit sRGB, so Display P3 colours are clipped to sRGB. Accepted and documented.

## 2. Answers to the handoff's open questions

1. **Do dynamic iMessage-app stickers reach the system Stickers drawer?** Yes, by opt-in. Set `MSSupportedPresentationContexts`
   to `[MSMessagesAppPresentationContextMessages, MSMessagesAppPresentationContextMedia]` in the extension's Info.plist. Apple
   documents the media context as appearing "inside the Stickers app throughout iOS including in Messages, FaceTime, the
   emoji keyboard, and Markup". The cost: with both values the extension runs only in the media context, where only inserting
   stickers or images is allowed. That is all this extension does. `NSStickerSharingLevel = OS` is set too (a documented iOS 17 key
   that the Sticker Pack template uses); its effect on code-based extensions is undocumented. *Not verified on a device.*
2. **Public API to add to the system sticker library?** None, iOS 17 through 27.2. Apple's `StickerKit`/`StickerFoundation`
   frameworks in the SDK have no public symbols (only SPI in the .tbd). The app offers the user-driven route instead: Save to
   Photos, then *Add Sticker* in Photos. It works on transparent PNGs, since Vision re-lifts them (IoU 0.92–0.99 in a macOS proxy test).
3. **WhatsApp / Telegram:** both have official import APIs, and both are implemented (`StickerExport`).
   - WhatsApp needs exactly 512×512 WebP ≤ 100 KB, 3–30 per pack, and a 96×96 PNG tray icon.
   - **ImageIO cannot encode WebP** (checked on iOS 27.2 and macOS 27.2), so the package depends on `SDWebImage/libwebp-Xcode` 1.6.0
     (BSD-3). Lossy q80 with an alpha plane gives 20–50 KB.
   - Telegram takes PNG with one side exactly 512 px. Its thumbnail must be a `{data, mimeType}` object: the client parses that,
     not the plain string the official SDK sends.
   - Signal has no import API; the keyboard covers it.
4. **MSSticker limits:** see finding 5 (PNG/GIF/JPEG, ≤ 500 KB, 300–618 px per side, description ≤ 150 characters).

Other platform facts that shaped the design:
- Vision's instance masks don't run in the iOS Simulator ("Could not create inference context"), so the editor falls back to the whole image.
- **Keyboards can only insert text.** `UITextDocumentProxy` has no image or adaptive-glyph API, so the keyboard copies a PNG.
  - With Full Access off, the App Group is **readable but not writable** (current Apple doc; confirmed in the simulator, where
    the keyboard lists the stickers), and pasteboard writes need Full Access.
  - App Review 4.4.1 asks keyboards to provide typed characters and to work without Full Access. The first version had a
    QWERTY/123 layout for this. It was later removed at the owner's request so the sticker grid gets the whole keyboard,
    which is a review risk to address in the review notes.
- Copies are PNG-only and ≤ 512 px. `pasteboard.image = UIImage` would also publish a JPEG without alpha. Signal keeps
  transparency only up to 512 px, and Telegram's client turns a pasted transparent PNG into a sticker.
- Apple ships a `[system] StickerKit` module in the device and macOS SDKs but not the simulator SDK, hence the package name `StickerizeKit`.
- Xcode 27's actool still requires the multi-size iMessage icon set (12 slots, no 1x).
- `CODE_SIGNING_ALLOWED=NO` builds drop the simulator entitlements, so App Groups fail at runtime.

## 3. What was built

See `README.md` for the layout. In short:
- The **app** imports from Photos, Files, paste, and drag and drop.
- The **editor** detects subjects, lets you pick subjects by tapping or with chips, and offers crop, outline, name and emoji.
- The **library** supports copy, share, drag, Save to Photos, reorder to front, delete, and WhatsApp/Telegram export.
- **Extensions:** the iMessage/Stickers-drawer browser, the keyboard (a sticker picker), and a Share extension using the same editor.
- **Storage:** an App Group store with coordinated, atomic writes; a manifest that rebuilds itself from the PNGs if it is lost or
  corrupt; Darwin notifications so every process reloads; and a visible fallback when the App Group is missing.

## 4. Verification

- `swift test` on macOS: **68 tests** pass: core 48, Vision/outline 12, export 8.
- The same bundles run **inside the iOS 27.2 simulator** (`simctl spawn … xctest`): core 38/38 and export 8/8 pass. Outlines 3/3
  pass, and the 9 Vision tests skip as expected.
- `xcodebuild` builds for the simulator and for device (`CODE_SIGNING_ALLOWED=NO`, compile only) with **zero warnings**.
- In the simulator, driven by Debug-only launch arguments (`Shared/DebugLaunch.swift`) and screenshots:
  - **Launch:** all three extensions register with pluginkit, and the App Group container is created.
  - **Imports:** 9 files (JPEG, EXIF-rotated JPEG, HEIC, PNG cut-outs, WebP, PDF) all saved within MSSticker limits.
  - **Screens:** library, editor, detail, setup, selection and WhatsApp export render in light and dark mode.
  - **Copy:** places exactly one pasteboard item, `public.png`, 512 px, with alpha (checked via `simctl pbsync`).
  - **Keyboard:** enabled through simulator preferences, it runs in both the app and Messages. Without Full Access it lists the
    stickers and shows the banner.

## 5. Not verified, and why

- **UI tests weren't run.** In the review environment `xcodebuild test` couldn't launch tests (Developer Tools access
  wasn't available), so UI flows were checked with the Debug launch arguments and screenshots instead. The UI test
  target and scheme are in place.
- **Needs a device or manual taps:**
  - Vision lifting on iOS; in the simulator, tests run on macOS only.
  - The Messages/Stickers-drawer UI.
  - The keyboard with Full Access on (granting it needs Settings taps).
  - The Share extension UI.
  - WhatsApp/Telegram import end to end; neither app can be installed in the simulator.
  - How WhatsApp treats a pasted transparent PNG.
- Keyboard memory limits aren't enforced in the simulator. The keyboard decodes only ~264 px thumbnails into a 12 MB cost-limited
  cache, and the copy path decodes at most one ≤ 618 px image.

## 6. Second review pass

After the first working build, four independent reviewers (core library; concurrency and memory; platform and App Store;
app UX and accessibility) read the code. A separate skeptic then tried to refute each reviewer's findings. Of 21
findings, 19 were confirmed, 2 were plausible and none were refuted. All are fixed. The verifiers rechecked the fixes in
the tree, and their few follow-ups are applied.

| Finding | Fix |
| --- | --- |
| Share extension decoded all 10 shared images up front (~70–85 MB before Vision), likely past its memory limit. The app did the same at 2048 px. | Imports keep only a file copy or the encoded data, validated from the header. The editor decodes one image at a time, off the main thread. Temporary copies are deleted afterwards. |
| Telegram PNG could exceed 512 KB when a dense sticker is scaled back up to 512 px; one failure sank the pack, with a wrong "WebP" message. | Opaque stickers are written without alpha, and an adaptive detail-reduction loop runs until the PNG fits. Errors name the sticker. |
| Skipped or cancelled editors kept running Vision and then a render; superseded renders ran in parallel. | The Vision request is cancelled with the task (`VNRequest.cancel`), and renders are serialized. |
| Skip or Cancel during a save could double-advance the batch or finish the Share extension twice. | Both are disabled while saving, callbacks are tied to their item, and finishing happens once. |
| Pack export decoded every sticker before encoding (~300 MB peak for 120). | Each sticker is decoded inside the loop. |
| Export Cancel didn't stop a running export, which later opened WhatsApp anyway; Cancel also cleared the selection. | The export is cancellable, dismissal is disabled while it runs, and cancel and success are separate callbacks. |
| Dragging a tile and letting go inside the app imported a duplicate. | Own-process marker type on drags; the library refuses them. |
| Photo loads showed no progress, dropped failures silently, and a second pick could replace the open editor. | Loading moved into the model: progress from the first item, failures counted, import disabled while busy. |
| iPad: one model drove every window's editor sheet. | Single-window scene manifest. |
| Share sheet could never offer PDFs, though the code accepted them. | The extension now filters images only, matching its activation rule. PDFs import through Files in the app. |
| No `ITSAppUsesNonExemptEncryption`: every upload stops at Missing Compliance. | Set to false. |
| Smaller UI issues: | |
| — keyboard notice drawn over the grid | now a banner above it |
| — "+" covering the last iMessage sticker | content inset |
| — fixed keyboard height in landscape | shorter keyboard |
| — VoiceOver not announcing copy results | announced |
| — stale key labels | fixed |
| — emoji limit not enforced | fixed |
| — unlocalized editor title | fixed |
| — dark-mode accent contrast 2.69:1 | now 3.4:1 for bold white text, 5:1 for accent text |
| — CLI `--outline` width wrong with `--full-size` or upscaling | measured within 1 px of the request |

Found in the simulator rather than by the reviewers:
- The "couldn't open" alert was dropped because it fired under the editor sheet; it now waits for the sheet to close.
- The disabled "Remove Background" switch showed on when Vision was unavailable.
- Vision's raw error text was shown to users.
- Grid tiles weren't square.

## 7. Found in device testing

- **The iMessage app showed no stickers.** The extension assigned `stickerBrowserView.dataSource` on an
  `MSStickerBrowserViewController` it owned. Before the controller's view loads, `stickerBrowserView` isn't there yet,
  so that assignment was silently dropped. When the view loads, the controller makes itself the data source and reports
  zero stickers. Both steps were reproduced in the iOS 27.2 simulator. The fix is Apple's documented pattern: a subclass
  that overrides `numberOfStickers(in:)` and `stickerBrowserView(_:stickerAt:)`. The simulator shows its count reaching
  the browser view. The extension also reloads when its size changes, reads the library without file coordination (it
  never writes), and logs how many stickers it loaded (subsystem: the extension's bundle ID, category `stickers`).
- **Photos imports were always named "Sticker".** The picked file's name was discarded. Imports now keep the delivered
  file name and convert it (`StickerName`): "funny_cat.png" becomes "funny cat". Camera, screenshot and temporary names
  such as `IMG_1234` still get "Sticker".

## 8. Animated stickers

Added after device testing, at the owner's request.

Where a GIF can go:
- **iMessage:** `MSSticker.h` allows GIF alongside PNG, under the same 500 KB and 300–618 px limits.
- **Signal** (Signal-iOS 3ace2d5, `PasteboardAttachment.swift`, `MimeTypeUtil.swift`): a pasted `com.compuserve.gif`
  is accepted as an image attachment. GIF is in its definitely-animated set, so it is sent animated.
- **Telegram** (Telegram-iOS fb0e62b, `ChatTextInputPanelNode.handlePastedMedia`): a pasted GIF is sent as a GIF
  animation, not a sticker. A pasted `public.heics` takes the animated-sticker path; that isn't used yet.
- **WhatsApp:** animated stickers need animated WebP in all-animated packs. Not done: packs use each sticker's first frame.

How it works:
- Imports with more than one frame (GIF, APNG, animated WebP, HEICS) are decoded with each frame's own delay and the
  loop count. Delays under 20 ms play at 100 ms, as browsers do. Frames are sampled evenly to stay within a memory
  budget: 48 MB in the app, 24 MB in the Share extension.
- `AnimatedStickerEncoder` writes GIF under the same canvas rules as stills. When it's over 500 KB, it first shrinks to
  about 420 px, then drops every other frame while staying at or above 8 fps (dropped frames' time goes to the kept
  ones), then shrinks to the 300 px minimum, then drops more frames.
- Stickers record their format in the manifest. Manifests without it are PNG.
- The keyboard and Copy put the GIF bytes alone on the pasteboard (`com.compuserve.gif`, checked with `simctl pbsync`).
- Grids show the first frame with a GIF badge; the editor and sticker page play the animation.

Measured in the simulator:

| Input | Result |
| --- | --- |
| 16-frame transparent GIF, 554 KB | 16 frames, 451 px, 479 KB |
| 16-frame animated WebP | 16 frames, 473 px, 473 KB |
| 60-frame 800×600 photo GIF, 21 MB | 30 frames, 300 px, 433 KB |

All three kept their full duration. A first encoder version alternated shrinking and dropping frames, and left the
photo GIF at 4 frames; the order above fixed that.
