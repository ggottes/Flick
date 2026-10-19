# Releasing Flick

Two distribution channels, two flavors. Both use the same `applicationId`
(`com.mossapps.flick`), so they are install-compatible; only the manifest
differs.

## Google Play

```bash
flutter build appbundle --flavor play --release
```

- Output: `build/app/outputs/bundle/playRelease/app-play-release.aab`
- Upload the bundle and bump the version code (current: `0.23.0-beta.1+30`).
- The `play` flavor does **not** declare `MANAGE_EXTERNAL_STORAGE`. The
  All Files Access declaration no longer applies to this build — **do not
  resubmit it**. It was rejected twice (see
  [`DSD_SCAN_ALL_FILES_PLAN.md`](DSD_SCAN_ALL_FILES_PLAN.md)); retrying
  risks escalating enforcement.
- Play builds silently use the scoped MediaStore/SAF scan path. The Full
  Library Access row is hidden at runtime by `isAllFilesAccessSupported()`.

## GitHub Releases

```bash
flutter build apk --flavor full --release
```

- Output: `build/app/outputs/apk/full/release/app-full-release.apk`
- The `full` flavor declares `MANAGE_EXTERNAL_STORAGE` and keeps the Rust
  direct-walk scanner for complete DSD/WavPack coverage
  (`android/app/src/full/AndroidManifest.xml`).
- Attach the APK to the GitHub release.

## Checks before publishing

```bash
flutter analyze
flutter test
```

Both flavors ship from CI/one machine with `ANDROID_NDK_HOME` set — see
[`ANDROID_NDK_SETUP.md`](ANDROID_NDK_SETUP.md).

## Building in CI

`.github/workflows/release-apk.yml` builds a signed release APK:

- **On a `v*` tag** it builds the `full` flavor, attaches
  `flick_<version>-release_full.apk` plus a bare-hex `.sha1` to the GitHub
  Release, and creates the release as a **prerelease** if it does not exist
  yet. Publish it by hand once the notes are ready.
- **`workflow_dispatch`** builds whichever flavor you pick and leaves the APK
  as a workflow artifact (14 days); no release is touched.

The runner needs the packages the app declares but the image lacks: platform
37, build-tools 37, and NDK 28.2 (matching `flutter.ndkVersion`). The workflow
installs all three and exports `ANDROID_NDK_HOME`, which `copyNdkLibs` uses to
find `libc++_shared.so`.

### Repository secrets

| Secret | Required | Value |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | yes | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | yes | keystore password |
| `ANDROID_KEY_ALIAS` | yes | key alias |
| `ANDROID_KEY_PASSWORD` | yes | key password |
| `GOOGLE_SERVICES_JSON` | no | the real `google-services.json` |
| `GOOGLE_SERVICES_JSON_BASE64` | no | same document, base64, if your secret store rejects multi-line values |

The four signing secrets are the same values `android/key.properties` holds
locally. Without them the workflow fails immediately with the list above rather
than producing an unsigned or throwaway-key APK — either would break updating
over an existing install.

`google-services.json` is gitignored and the app does not initialise Firebase,
but `com.google.gms.google-services` is applied in `android/app/build.gradle.kts`
and hard-fails when the file is missing. The workflow writes a minimal
placeholder when neither secret is present.
