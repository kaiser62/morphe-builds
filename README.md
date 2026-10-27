# morphe-builds

Automated [Morphe](https://morphe.software)-patched Android builds, published as one combined release.

| App | Package | Patch source |
|---|---|---|
| Instagram (clone) | `com.instagram.android` → `com.instagram.android.piko` | [crimera/piko](https://github.com/crimera/piko) |
| Twitter / X | `com.twitter.android` | [crimera/piko](https://github.com/crimera/piko) |
| YouTube | `com.google.android.youtube` | [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) |
| YouTube Music | `com.google.android.apps.youtube.music` | [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) |
| Reddit | `com.reddit.frontpage` | [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) |
| Facebook | `com.facebook.katana` | [RookieEnough/De-Vanced](https://github.com/RookieEnough/De-Vanced) |
| Messenger | `com.facebook.orca` | [SysAdminDoc/HushMessenger](https://github.com/SysAdminDoc/HushMessenger) |
| ProtonVPN | `ch.protonvpn.android` | [rushiranpise/morphe-patches](https://github.com/rushiranpise/morphe-patches) |

All APKs are `arm64-v8a`. The applied patches for each app are listed in every release's notes.

## How it works

`.github/workflows/build.yml` runs every 6 hours (and on demand from the Actions tab):

1. **setup** – reads `apps.json`, finds the previous `builds-*` release, checks the signing key secret.
2. **build** (one job per app, in parallel) – `build.sh`:
   - downloads the latest release `.mpp` of the app's patch source;
   - reads which app versions those patches support and picks the newest one;
   - if the previous release already holds that exact app version + patch version, reuses its APK (no download, no patching);
   - otherwise downloads the app (APKPure via [apkeep](https://github.com/EFForg/apkeep), or the vendor's own GitHub releases when `src` is set), falling back to older supported versions if the newest isn't available, then patches and signs it. A patch that fails to apply is skipped (`--continue-on-error`) and left out of the notes.
3. **release** – `release.sh` merges every app's result into `state.json`. If any app changed, it publishes a new release `builds-YYYY.MM.DD-HHMM` with all APKs, `state.json` and notes (version table + per-app patch list). If an app failed this run, its APK from the previous release is carried forward. If nothing changed, nothing is published.

Run with **force** checked to publish even when nothing changed.

## Signing

Every APK is signed with one permanent key (secrets `KEYSTORE_B64`, `KEYSTORE_PASSWORD`), so new builds install over old ones. The patched apps' signature differs from the official apps', so the first install needs the official app removed (Instagram is a clone and installs alongside it). Lose the key and every app must be reinstalled — keep a backup.

## Updating on the phone

Use [Obtainium](https://github.com/ImranR98/Obtainium):

1. Settings → add a GitHub personal access token (repo is private).
2. Add app → `https://github.com/kaiser62/morphe-builds`, set **Filter APKs by regular expression**, e.g. `^instagram-.*\.apk$`.
3. Repeat per app (`twitter-`, `youtube-`, `youtube-music-`, `reddit-`, `facebook-`, `messenger-`, `protonvpn-`).

YouTube / YouTube Music need [MicroG-RE](https://github.com/MorpheApp/MicroG-RE) installed for Google sign-in.

## Adding an app

Add a line to `apps.json`:

```json
{ "id": "name", "pkg": "com.example.app", "patches": "owner/patch-repo", "args": "", "src": "" }
```

- `patches` – patch source repo; comma-separate fallbacks tried in order when no supported app version can be downloaded
- `args` – extra patcher options, e.g. `-e Clone -O packageName=...`
- `src` – optional `owner/repo:asset-glob` to download the app from the vendor's GitHub releases (release tag = app version) instead of APKPure.

Patch sources can be found at [morphe-patches.software](https://morphe-patches.software/#apps).
