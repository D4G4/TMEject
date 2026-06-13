# Release setup (one-time)

Operational runbook for the first release. Run each section once on the machine you'll be
releasing from; the artifacts (keychain entries, keychain profile, Sparkle key pair) persist
across reboots and across Xcode upgrades.

This document is NOT a feature spec — it's a checklist. If a step fails, fix it before moving
on; later steps depend on earlier ones.

## 1. Sparkle EdDSA key pair

Sparkle signs each release with an EdDSA private key; clients verify with the public half
that's compiled into the app's Info.plist. You generate the key pair ONCE per project and
keep the private key in your login keychain forever. **If you lose it, every shipped client
stops trusting updates until you ship them a manually-installed new app with a new public
key.** That's a forced reinstall for every user. Treat it like a code-signing identity.

```
# Download Sparkle: https://github.com/sparkle-project/Sparkle/releases (latest 2.x).
# Unzip somewhere persistent, e.g. ~/Tools/Sparkle.
cd ~/Tools/Sparkle/bin
./generate_keys
```

`generate_keys` prints the PUBLIC EdDSA key to stdout and silently stores the PRIVATE key in
your login keychain under the item "https://sparkle-project.org" (account name: ed25519).

Paste the printed PUBLIC key into `project.yml` at
`INFOPLIST_KEY_SUPublicEDKey`. Re-run `xcodegen generate` so the change reaches the Info.plist.

**Verify** the public key is in the built Info.plist:

```
xcodebuild build ...
plutil -p build/.../TMEject.app/Contents/Info.plist | grep SUPublicEDKey
```

## 2. Install `generate_appcast` on PATH

The release script uses Sparkle's `generate_appcast` to build/refresh `releases/appcast.xml`
from the zips in `releases/`. It reads the private key from your keychain (set up in step 1).

```
sudo cp ~/Tools/Sparkle/bin/generate_appcast /usr/local/bin/
generate_appcast --help   # smoke check
```

## 3. Developer ID Application certificate

Notarized macOS apps require a Developer ID Application certificate. Open Xcode → Settings →
Accounts → your Apple ID → Manage Certificates → "+" → Developer ID Application. The
certificate lands in your login keychain automatically.

**Verify**:

```
security find-identity -p codesigning -v | grep "Developer ID Application"
```

You should see one identity line; if you have multiple, pick one and note the SHA1 hash for
`TMEJECT_CODESIGN_IDENTITY` overrides if the auto-selection ever picks the wrong one.

## 4. `notarytool` keychain profile

Notarytool stores Apple-ID credentials in your keychain under a named profile so you don't
type them on every release. **Generate an app-specific password** at https://appleid.apple.com/
→ Sign-In and Security → App-Specific Passwords ("TMEject Notarization") — DON'T use your
real Apple ID password.

```
xcrun notarytool store-credentials TMEjectNotary \
    --apple-id you@example.com \
    --team-id ABCDE12345 \
    --password xxxx-xxxx-xxxx-xxxx
```

The profile name `TMEjectNotary` is the default the release script looks for; override via
the `TMEJECT_NOTARY_PROFILE` env var if you want a different name.

**Verify**:

```
xcrun notarytool history --keychain-profile TMEjectNotary
```

Should return your past submissions (empty if this is the first time, but the call must not
error — that's the preflight `release.sh` runs before doing 4 minutes of archive work).

## 5. GitHub Pages

The Info.plist `SUFeedURL` points at
`https://d4g4.github.io/TMEject/appcast.xml`. For that URL to resolve:

1. On GitHub.com, repo Settings → Pages → set "Source: Deploy from a branch" → branch
   `gh-pages` (create it if it doesn't exist; root path is fine).
2. Create the branch locally if needed:

```
git checkout --orphan gh-pages
git rm -rf .
echo "TMEject release artifacts" > README.md
git add README.md
git commit -m "Init gh-pages"
git push -u origin gh-pages
git checkout main
```

3. Wait a minute for the first Pages deploy. Hitting the bare
   `https://d4g4.github.io/TMEject/` should return the README; once you push a release
   `appcast.xml + .zip` there, the SUFeedURL will resolve.

## 6. Smoke test

Before any real release:

```
./scripts/release.sh 0.0.1-test
```

The script will refuse to run until steps 1–4 are done (preflight checks). On success it
writes `releases/TMEject-0.0.1-test.zip` and `releases/appcast.xml`. Inspect the appcast for
the right SUFeedURL prefix, signature, and pubdate.

DO NOT push the test release to gh-pages — the version string will trip update prompts on
real users' installs. Delete the test artifacts before doing a real release.

## Going forward

Releases are then:

```
./scripts/release.sh 0.2.0
# inspect releases/, then publish per the script's printed instructions
```

The first release will surface any edge cases this runbook missed — when that happens, file
them back here.
