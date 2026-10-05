# Contributing to OpenHeadPointer

Thanks for helping. OpenHeadPointer is an early prototype, so small, focused changes are easiest to review.

## Setup

Requires macOS 15+ and Xcode (Swift 6).

```bash
swift test                  # unit tests for the pure logic in GazeCore
scripts/build-app.sh        # → build/OpenHeadPointer.app
open build/OpenHeadPointer.app
```

Build through the script, not `swift run`: macOS grants Camera and Accessibility access to an app bundle. The README explains how to create a local signing certificate so the Accessibility grant survives rebuilds.

## Layout

- `Sources/GazeCore/`: pure, testable logic (filters, pointer maths, blink detection). Add tests in `Tests/GazeCoreTests/` for anything here.
- `Sources/OpenHeadPointer/`: the menu-bar app (camera, Vision, UI, cursor control).

## Pull requests

- Keep each PR to one change and describe how you tested it. Camera behaviour is hard to unit test, so say which Mac and camera you tried.
- Match the surrounding code style; there are no third-party dependencies, and new ones need a good reason.
- Run `swift test` before opening the PR.
- Privacy is a hard rule: video stays on the device and is never stored or sent anywhere.

## Reporting bugs and ideas

Use the issue templates. For tracking problems, attach the performance log from the app's debug window if you can.

By contributing you agree that your work is released under the MIT licence in `LICENSE`.
