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

Two build inputs are **not** committed, because they carry the ThingsBoard app
secrets:

| File | Purpose | Source |
| --- | --- | --- |
| `configs.json` | dart-defines, passed with `--dart-define-from-file` | Secret Manager |
| `ios/Flutter/AppConfig.xcconfig` | iOS build settings Xcode reads (bundle id, display name, URL scheme) | generated from `configs.json` |

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

Both scripts pull the secret, write `configs.json`, and generate
`ios/Flutter/AppConfig.xcconfig` from it. Locally they use your own gcloud
credentials, so log in first:

```bash
gcloud auth application-default login
```

You need `roles/secretmanager.secretAccessor` on the secret.

The secret ID defaults to `SWIM-OS-MOBILE-CONFIGS-JSON`; override it with the
`CONFIG_SECRET` environment variable (or the `-ConfigSecret` parameter on
Windows).

### Building

```bash
flutter run   --dart-define-from-file=configs.json
flutter build apk --dart-define-from-file=configs.json
flutter build ipa --dart-define-from-file=configs.json
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

`configs.json` is the single source of truth. `android/app/build.gradle` reads it
through the dart-define bundle. Xcode cannot read dart-defines directly, so the
Runner scheme has a build pre-action that decodes `$DART_DEFINES` and writes
`ios/Flutter/AppConfig.xcconfig` on every build. `Debug.xcconfig` and
`Release.xcconfig` include that file after `TbDefault.xcconfig`. An xcconfig
applies the last assignment of a given variable, so the generated values
override the `TbDefault.xcconfig` defaults. The generated file is gitignored and
does not exist until the first build.

Checked-in fallbacks (`android/app/build.gradle`, `ios/Flutter/TbDefault.xcconfig`,
`lib/constants/app_constants.dart`) are set to the SWIM-OS values, so a build
without `configs.json` still targets the SWIM-OS instance and produces the right
identifiers.

Because `thingsBoardApiEndpoint` now has a default, `ignoreRegionSelection` is
always true and the region-selection screen is unreachable.

`ios/Runner/Runner.entitlements` is **not** templated — associated domains must
be literal, so `applinks:swim-os.aquawatchsolutions.com` is hardcoded there.
