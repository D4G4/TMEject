# downloads/

This directory ships the signed, notarized `.dmg` that the website's "Download
for Mac" buttons point at. It is intentionally empty in the repo — the DMG is
produced by `scripts/release.sh` and dropped here at release time.

## Drop conventions

The hero CTA and the download-section CTA both link to:

```
downloads/TMEject-latest.dmg
```

So every release **must** be available at that exact path (a copy or a symlink).
Versioned filenames live alongside it for archive purposes:

```
downloads/TMEject-latest.dmg            # always the most recent stable
downloads/TMEject-<version>.dmg         # e.g. TMEject-1.0.0.dmg
downloads/TMEject-<version>.dmg.sig     # Sparkle EdDSA signature, if not in appcast.xml
```

## Manual update steps (until release.sh automates this)

1. Build, sign, and notarize the DMG (see `docs/release-setup.md` in the repo
   root).
2. Copy the signed DMG into this folder under both names:
   ```
   cp TMEject-1.0.0.dmg site/downloads/
   cp TMEject-1.0.0.dmg site/downloads/TMEject-latest.dmg
   ```
3. Run `sign_update TMEject-1.0.0.dmg` (Sparkle 2.x tools) and paste the output
   into a new `<item>` in `site/appcast.xml`.
4. Commit the appcast change (NOT the DMG — `.dmg` is gitignored at the repo
   root) and deploy the site (see `site/README.md`).
5. Upload the DMG to the matching GitHub Release for users who don't enable
   Sparkle.

## Why no DMG in git

Binaries don't compress and bloat repo history. GitHub Pages serves whatever is
in the published `site/` directory at deploy time, so the DMG only needs to be
in place when the deploy runs — not in git.
