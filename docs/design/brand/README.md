`leyline-mark.svg` is the mark (a 13-unit ring and dot) and `leyline-splash.svg` the splash's 512×200 composition, both from the owner on 2026-09-25.
Neither is loaded by the app: both are drawn in code, the mark by `BrandMark` and the splash by `SplashView` (`app/Sources/LeylineApp`), with the SVGs' sizes as `Theme` tokens.
The icon is drawn at bundle time by `scripts/render-icon.swift` (CoreGraphics, macOS only), which `scripts/bundle-app.sh` runs; its 1024 px `AppIcon.iconset/icon_512x512@2x.png` is to be checked in here as `leyline-icon.png` after the first run on a Mac.
