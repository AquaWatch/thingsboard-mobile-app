## [ThingsBoard PE Mobile Application](https://thingsboard.io/products/mobile-pe/) is an open-source project based on [Flutter](https://flutter.dev/)
Powered by [ThingsBoard PE](https://thingsboard.io/products/thingsboard-pe/) IoT Platform

Build your own advanced IoT mobile application **with minimum coding efforts**

## Please be informed the Web platform is not supported, because it's a part of our main platform!

## Resources

- [Getting started](https://thingsboard.io/docs/pe/mobile/getting-started/) - learn how to set up and run your first IoT mobile app
- [Customize your app](https://thingsboard.io/docs/pe/mobile/customization/) - learn how to customize the app
- [Publish your app](https://thingsboard.io/docs/pe/mobile/release/) - learn how to publish app to Google Play or App Store

---

## SWIM-OS fork configuration

This fork is configured for `com.aquawatchsolutions.swimos` against
`https://swim-os.aquawatchsolutions.com`.

Three build inputs are **not** committed, because they carry the ThingsBoard app
secrets and the Firebase keys:

| File | Purpose | Source |
| --- | --- | --- |
| `config.json` | dart-defines, passed with `--dart-define-from-file` | Secret Manager |
| `ios/Flutter/AppConfig.xcconfig` | iOS build settings Xcode reads (bundle id, display name, URL scheme) | generated from `config.json` |
| `lib/firebase_options.dart` | FlutterFire options, imported by `lib/main.dart` | Secret Manager, or `flutterfire configure` |

They live in Google Secret Manager in the **RiverWatch** project
(`riverwatch-be1e4`) — see ENG-245.

### Bootstrap

One-time, then whenever the secrets change:

```bash
# macOS / Linux / Git Bash / CI
./scripts/fetch-secrets.sh
```

```powershell
# Windows
.\scripts\fetch-secrets.ps1
```

Both scripts pull the secrets, write `config.json`, generate
`ios/Flutter/AppConfig.xcconfig` from it, and write `lib/firebase_options.dart`.
Locally they use your own gcloud credentials, so log in first:

```bash
gcloud auth application-default login
```

You need `roles/secretmanager.secretAccessor` on the secrets.

Secret IDs default to `SWIM-OS-MOBILE-CONFIG-JSON` and
`SWIM-OS-MOBILE-FIREBASE-OPTIONS`; override with the `CONFIG_SECRET` /
`FIREBASE_OPTIONS_SECRET` environment variables (or the matching `-ConfigSecret`
/ `-FirebaseOptionsSecret` parameters on Windows).

> **`SWIM-OS-MOBILE-FIREBASE-OPTIONS` does not exist yet.** Until it is created,
> the scripts keep whatever `lib/firebase_options.dart` is already on disk, and a
> clean checkout has none -- `lib/main.dart` imports it, so the build will not
> compile. Either upload the file:
>
> ```bash
> gcloud secrets create SWIM-OS-MOBILE-FIREBASE-OPTIONS >   --project=riverwatch-be1e4 --data-file=lib/firebase_options.dart
> ```
>
> or generate it locally with `flutterfire configure --project=riverwatch-be1e4`.
> CI needs the secret, since a runner always starts from a clean checkout.

### Building

```bash
flutter run   --dart-define-from-file=config.json
flutter build apk --dart-define-from-file=config.json
flutter build ipa --dart-define-from-file=config.json
```

### CI

The same script runs unchanged on a runner — it just needs Application Default
Credentials in place first:

```yaml
- uses: google-github-actions/auth@v2
  with:
    project_id: riverwatch-be1e4
    workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

- uses: google-github-actions/setup-gcloud@v2

- name: Fetch build configuration
  run: ./scripts/fetch-secrets.sh
```

### Where the values land

`config.json` is the single source of truth. `android/app/build.gradle` reads it
through the dart-define bundle; Xcode cannot, so the iOS-facing subset is
projected into `ios/Flutter/AppConfig.xcconfig`, which `Debug.xcconfig` and
`Release.xcconfig` include *after* `TbDefault.xcconfig` so it wins.

Checked-in fallbacks (`android/app/build.gradle`, `ios/Flutter/TbDefault.xcconfig`)
are set to the SWIM-OS values, so a build without `config.json` still produces the
right identifiers rather than ThingsBoard's.

`ios/Runner/Runner.entitlements` is **not** templated — associated domains must
be literal, so `applinks:swim-os.aquawatchsolutions.com` is hardcoded there.
