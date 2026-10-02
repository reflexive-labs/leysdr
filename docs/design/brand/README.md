`leyline-mark.svg` is the mark (a 13-unit ring and dot), and `leyline-splash.svg` is the splash's
512 × 200 composition. The app draws both in code: `BrandMark` draws the mark and `SplashView`
draws the splash, using sizes from `Theme`.

`scripts/render-icon.swift` draws the app icon with CoreGraphics on macOS.
`scripts/bundle-app.sh` runs it and places the generated `AppIcon.icns` in the bundle. Generated
icon files are build outputs and are not checked in.
