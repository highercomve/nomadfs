# Google Play submission

- Application ID: `com.foreachdeveloper.nomadfs`
- Developer: Sergio A Marin. Support: sergio.alejandro.mz@gmail.com.
- Website: https://nomadfs.foreachdeveloper.com/
- Privacy: https://nomadfs.foreachdeveloper.com/privacy/ (`site/content/privacy.smd`)

The listing text is in `listing.md`. Artwork is in `assets/`: `play-icon.png` (512×512 RGBA),
`feature-graphic.png` (1024×500 RGB, from `feature-graphic.svg` with `rsvg-convert`), phone
screenshots (1082×1922, a Poco F3 at a 412×732 viewport) and Chromebook screenshots (1920×1080,
the ARC app maximized, a 1536×864 viewport). They are captures of the real app, through the
WebView's DevTools, with the devices renamed (Studio PC, Home server, Cloud relay, Android
phone, Pixel phone, Chromebook). Never capture other devices' shares: they may hold private files.

## Build and signing

The Play build turns off the app's own update check and APK download (`-Dplay-store=true`):
Google Play updates it.

    cd nomadfs-gui
    zig build -Doptimize=ReleaseSafe -Dplay-store=true -Dtarget=aarch64-linux-android
    zig build -Doptimize=ReleaseSafe -Dplay-store=true -Dtarget=x86_64-linux-android -Dcpu=baseline
    cd android
    d=~/.config/nomadfs/signing
    ORIEL_ANDROID_KEYSTORE=$d/play-upload.p12 ORIEL_ANDROID_KEY_ALIAS=nomadfs-upload \
    ORIEL_ANDROID_KEYSTORE_PASSWORD="$(cat $d/play-upload.password)" \
    ORIEL_ANDROID_KEY_PASSWORD="$(cat $d/play-upload.password)" ./gradlew bundleRelease

Upload `android/app/build/outputs/bundle/release/app-release.aab`, never an APK. Each upload needs
a larger version code: `versionCode` and `versionName` in `android/app/build.gradle.kts` follow
the release (MAJOR*10000 + MINOR*100 + PATCH; scripts/release.sh checks them).

The upload key (`nomadfs-upload`, RSA 4096) and its password are in `~/.config/nomadfs/signing/`,
mode 600, outside the repository; back them up. Google Play App Signing keeps the app signing key.
The public upload certificate is `play-upload-certificate.pem`, SHA-256
`B5:FD:4C:BE:85:C5:E9:60:D9:27:CB:6C:A1:5C:F3:02:DD:DB:F5:B6:CD:17:B0:82:F3:9D:22:56:73:D0:8E:E2`.
The GitHub APK is debug-signed: a device must uninstall it before installing the Play version
(its NomadFS data goes with it; rejoin the swarm with an invite).

## Console declarations

- All files access (`MANAGE_EXTERNAL_STORAGE`): core purpose is sync and backup of the folders the
  user picks, and saving downloads to the shared Download folder; scoped storage can't index and
  watch whole folders like Camera for backup.
- Foreground service, special use (`FOREGROUND_SERVICE_SPECIAL_USE`): keeps the node connected to
  the user's other devices while the app is in the background, when the user turns it on.
- Camera: scanning invite QR codes only.
- Data safety: no data collected by the developer; files and device information go only to the
  user's own paired devices, encrypted in transit; no account, ads or analytics.
- App access: no login. Reviewing it needs a second device in the same swarm (desktop or another
  Android device with NomadFS, joined with an invite code).

## Release track

New personal developer accounts need a closed test with at least 12 testers opted in for 14 days
before production access. Upload to internal testing first, then closed testing.

## Status

- 2026-10-30: app created in Play Console (Sergio A Marin, personal account); store listing,
  privacy policy, app access, ads, content rating (ESRB Teen / 12+: users interact), target
  audience 18+, data safety (no data collected or shared), category Tools.
- Internal testing: 311 (0.3.11) released 2026-10-30, testers "Amigos" and "GhostPantry owner".
  Opt-in: https://play.google.com/apps/internaltest/4701140950897222942
- Next: closed testing with at least 12 testers for 14 days, then apply for production.
