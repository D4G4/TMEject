# TMEject — marketing site

Single-page static site that markets and distributes TMEject.

Built from the Claude Design output (`site-reference/` in the repo root —
gitignored). Plain HTML/CSS, no build step, no analytics, no third-party
scripts, no network fonts. Deploys to GitHub Pages as-is.

Lives at: <https://d4g4.github.io/TMEject/>

## Layout

```
site/
├── index.html      ← landing page (paged scroll-snap layout)
├── style.css       ← design-token stylesheet (light + dark)
├── appcast.xml     ← Sparkle release feed (placeholder until first ship)
├── assets/
│   └── icon.png    ← 1024×1024, copied from the app's AppIcon.appiconset
└── downloads/
    └── README.md   ← DMG drop conventions (the DMG itself is gitignored)
```

## Design fidelity

Matches the macOS app's design tokens in `TMEject/UI/DesignTokens.swift`:

- **Ritual teal** is `oklch(0.62 0.085 195)` in light and
  `oklch(0.74 0.085 195)` in dark — used ONLY on the primary CTA, the active
  page-dot, the ritual moment, and the "Eject & Lock" feature accent. Same
  restraint as the app.
- **Font** is the macOS system stack
  (`-apple-system, "SF Pro Text", "SF Pro Display", system-ui, ...`) with
  `SF Mono` for the error tag.
- **Light/dark** via `@media (prefers-color-scheme)` — no JS toggle, follows
  the OS.
- **No emoji**, no gradients beyond a single radial accent glow, no decorative
  illustrations.

## Local preview

```sh
python3 -m http.server -d site 8000
```

then open <http://localhost:8000>.

Test light/dark by toggling **System Settings → Appearance** while the page is
open — the CSS responds live.

## Deploy (GitHub Pages)

The repo is set up to publish `site/` from `main` via the
**Settings → Pages → Source = "Deploy from a branch"** route, with
**Branch = `main`** and **Folder = `/site`**. Pushing to `main` is enough; no
GitHub Action needed.

First-time setup (once per repo):

1. Push the `site/` directory to `main`.
2. **Settings → Pages →** Source: *Deploy from a branch*, Branch: `main`,
   Folder: `/site`. Save.
3. Wait ~30s for the first build; the site URL appears at the top of the Pages
   settings page.
4. Optional: add `CNAME` to `site/` and configure DNS if you want a custom
   domain. Leave `appcast.xml`'s `<link>` matching whichever URL Sparkle will
   actually fetch from.

## Updating the DMG between releases

1. Build, sign, notarize: `scripts/release.sh` (or the manual flow in
   `docs/release-setup.md`).
2. Drop the signed DMG into `site/downloads/` as both
   `TMEject-<version>.dmg` and `TMEject-latest.dmg` (the hero CTA links to
   `TMEject-latest.dmg`).
3. Append a new `<item>` to `site/appcast.xml` with the EdDSA signature from
   `sign_update`.
4. Commit the `appcast.xml` change (the DMGs are gitignored — see the repo
   `.gitignore`). Push to `main`; GitHub Pages republishes within a minute.
5. Sparkle clients pick up the new version on their next check.

See `site/downloads/README.md` for the file naming spec.

## What's NOT here (on purpose)

- **No JS framework, no bundler.** Vanilla HTML/CSS with one inline
  `IntersectionObserver` script for the reveal animation + page-dot
  highlighting.
- **No CDN fonts.** The macOS system font stack only.
- **No analytics, no trackers, no third-party scripts.** A self-contained page.
- **No light/dark toggle UI.** OS-driven. Adding a toggle would mean
  persistence and that's noise for a single download page.
