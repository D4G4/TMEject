# TMEject — marketing site

Single-page static site that markets and distributes TMEject.

Built from the Claude Design v2 output (`site-reference/` in the repo root —
gitignored). Plain HTML/CSS, no build step, no analytics, no third-party
scripts, no network fonts. Deploys to GitHub Pages as-is.

Lives at: <https://d4g4.github.io/TMEject/>

## Layout

```
site/
├── index.html      ← landing page (paged scroll-snap; hero is a faux macOS desktop)
├── style.css       ← single stylesheet (light + dark via prefers-color-scheme)
├── appcast.xml     ← Sparkle release feed (placeholder until first ship)
├── assets/
│   └── icon.png    ← 1024×1024, copied from the app's AppIcon.appiconset
└── downloads/
    └── README.md   ← DMG drop conventions (the DMG itself is gitignored)
```

## Design — the v2 metaphor

The page is dressed as a real macOS desktop:

- The fixed top bar is the **macOS menu bar**, doing double duty as the site
  nav. The active section's link gets the macOS "open menu" blue highlight as
  you scroll.
- The hero is a **dark macOS desktop**, with the headline as desktop content
  and a **live TMEject popover** floating in the top-right, its arrow aligned
  to the TMEject icon in the menu bar.
- Each section is a **full-height snap page**: spacebar / arrows / scroll
  advance one whole screen at a time, no mid-content slicing.
- When you reach the "How it works" section, the live popover **animates
  through all five states** (idle → backing up → confirming → ejecting →
  failed), syncing with the menu-bar icon and a list on the left.
- Right-edge **page dots** track position; the active dot turns ritual-teal.

## Design fidelity

Matches the macOS app's design tokens:

- **Ritual teal** is `oklch(0.62 0.085 195)` in light and
  `oklch(0.74 0.085 195)` in dark. Used ONLY on the primary CTA, the active
  page-dot, the eyebrow type, the ritual moment ring, and the keystroke "E"
  cap. Same restraint as the app.
- **Font** is the macOS system stack
  (`-apple-system, "SF Pro Text", "SF Pro Display", system-ui, ...`) with
  `SF Mono` for the error tag.
- **Light/dark** via `@media (prefers-color-scheme)` — no JS toggle, follows
  the OS.
- **Product-shot surfaces** (the hero desktop, the floating popover, the
  ritual confirm card) stay dark in both modes — they represent the
  translucent macOS app over whatever desktop the user has, so flipping them
  to light would break the illusion.
- **No emoji**, no decorative illustrations, no marketing language.

## Local preview

```sh
python3 -m http.server -d site 8000
```

then open <http://localhost:8000>.

Test light/dark by toggling **System Settings → Appearance** while the page is
open — the CSS responds live. (The hero desktop and live popover stay dark in
both modes by design.)

## Deploy (GitHub Pages)

The repo is set up to publish `site/` from `main` via
**Settings → Pages → Source = "Deploy from a branch"**, with
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

- **No JS framework, no bundler.** Vanilla HTML/CSS with one inline script
  for the live popover state machine, scroll-driven section highlighting, and
  popover-arrow alignment.
- **No CDN fonts.** The macOS system font stack only.
- **No analytics, no trackers, no third-party scripts.** A self-contained page.
- **No light/dark toggle UI.** OS-driven. Adding a toggle would mean
  persistence and that's noise for a single download page.
- **No IntersectionObserver / requestAnimationFrame.** Scroll-driven
  highlighting uses a plain scroll handler; the state-machine progress uses
  `setInterval`. Both proved more reliable across embeddings during the
  design iteration.
