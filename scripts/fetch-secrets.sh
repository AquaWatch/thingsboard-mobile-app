#!/usr/bin/env bash
#
# Pulls the SWIM-OS mobile build configuration out of Google Secret Manager and
# materialises the files that are deliberately kept out of git:
#
#   config.json                     dart-defines consumed via --dart-define-from-file
#   ios/Flutter/AppConfig.xcconfig  generated from config.json, consumed by Xcode
#   lib/firebase_options.dart       FlutterFire output (optional secret)
#
# Used by CI and by local dev. Locally it authenticates with your own gcloud
# login; on a runner it uses whatever ADC the auth step put in place.
#
#   ./scripts/fetch-secrets.sh
#
set -euo pipefail

# --- Secret Manager coordinates (ENG-245) ------------------------------------
# Secret IDs may only contain [A-Za-z0-9_-]; there is no literal "config.json"
# secret. Override any of these with an env var if the IDs change.
GCP_PROJECT="${GCP_PROJECT:-riverwatch-be1e4}"
CONFIG_SECRET="${CONFIG_SECRET:-SWIM-OS-MOBILE-CONFIG-JSON}"
CONFIG_SECRET_VERSION="${CONFIG_SECRET_VERSION:-latest}"
FIREBASE_OPTIONS_SECRET="${FIREBASE_OPTIONS_SECRET:-SWIM-OS-MOBILE-FIREBASE-OPTIONS}"
FIREBASE_OPTIONS_SECRET_VERSION="${FIREBASE_OPTIONS_SECRET_VERSION:-latest}"
# -----------------------------------------------------------------------------

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config_file="config.json"
xcconfig_file="ios/Flutter/AppConfig.xcconfig"
firebase_file="lib/firebase_options.dart"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v gcloud >/dev/null 2>&1 \
  || die "gcloud not found on PATH. Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install"

# Probe by executing, not by presence on PATH: on Windows, `python3` is often a
# Microsoft Store "app execution alias" that resolves but cannot run.
python_bin=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" >/dev/null 2>&1; then
    python_bin="$candidate"
    break
  fi
done
[ -n "$python_bin" ] || die "a working python3 (or python) is required to render $xcconfig_file"

access_secret() {
  # access_secret <secret-id> <version> -> secret payload on stdout
  gcloud secrets versions access "$2" --secret="$1" --project="$GCP_PROJECT"
}

normalize_file() {
  # LF endings, exactly one trailing newline. Keeps this script and its
  # PowerShell twin byte-identical, so switching between them is not a diff.
  "$python_bin" - "$1" <<'PY'
import io, sys
path = sys.argv[1]
text = io.open(path, encoding='utf-8-sig', newline='').read()
text = text.replace('\r\n', '\n').replace('\r', '\n').rstrip('\n') + '\n'
io.open(path, 'w', encoding='utf-8', newline='').write(text)
PY
}

# --- config.json -------------------------------------------------------------
log "==> Fetching $CONFIG_SECRET:$CONFIG_SECRET_VERSION from $GCP_PROJECT"
tmp_config="$(mktemp)"
trap 'rm -f "$tmp_config"' EXIT

if ! access_secret "$CONFIG_SECRET" "$CONFIG_SECRET_VERSION" > "$tmp_config" || [ ! -s "$tmp_config" ]; then
  die "could not read secret '$CONFIG_SECRET' from project '$GCP_PROJECT'.
  - Confirm the secret ID (set CONFIG_SECRET=<id> to override).
  - Confirm you are logged in:  gcloud auth application-default login
  - Confirm you hold roles/secretmanager.secretAccessor on the secret."
fi

"$python_bin" -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$tmp_config" \
  || die "secret '$CONFIG_SECRET' is not valid JSON"

mv "$tmp_config" "$config_file"
trap - EXIT
normalize_file "$config_file"
log "    wrote $config_file"

# --- ios/Flutter/AppConfig.xcconfig ------------------------------------------
# Xcode cannot read dart-defines, so the iOS-facing subset of config.json is
# projected into an xcconfig that Debug.xcconfig/Release.xcconfig include after
# TbDefault.xcconfig (later include wins).
mkdir -p "$(dirname "$xcconfig_file")"
"$python_bin" - "$config_file" "$xcconfig_file" <<'PY'
import json, sys

src, dest = sys.argv[1], sys.argv[2]
cfg = json.load(open(src, encoding='utf-8'))

# xcconfig variable <- config.json key
MAPPING = [
    ('IOSAPPLICATIONID',             'iosApplicationId'),
    ('IOSAPPLICATIONNAME',           'iosApplicationName'),
    ('REGISTRATIONREDIRECTURLHOST',  'registrationRedirectUrlHost'),
    ('REGISTRATIONREDIRECTURLSCHEME', 'registrationRedirectUrlScheme'),
    ('APPLINKSURLHOST',              'appLinksUrlHost'),
]

lines = ['// Generated from config.json by scripts/fetch-secrets. Do not edit.']
for var, key in MAPPING:
    value = cfg.get(key)
    if value in (None, ''):
        continue
    value = str(value)
    if '//' in value:
        raise SystemExit("error: %s contains '//', which xcconfig parses as a comment" % key)
    lines.append('%s=%s' % (var, value))

open(dest, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')
PY
log "    wrote $xcconfig_file"

# --- lib/firebase_options.dart -----------------------------------------------
log "==> Fetching $FIREBASE_OPTIONS_SECRET:$FIREBASE_OPTIONS_SECRET_VERSION"
tmp_firebase="$(mktemp)"
# This secret is optional, so gcloud's own error is noise when it is absent --
# the branches below explain the outcome instead.
if access_secret "$FIREBASE_OPTIONS_SECRET" "$FIREBASE_OPTIONS_SECRET_VERSION" > "$tmp_firebase" 2>/dev/null && [ -s "$tmp_firebase" ]; then
  mv "$tmp_firebase" "$firebase_file"
  normalize_file "$firebase_file"
  log "    wrote $firebase_file"
elif [ -f "$firebase_file" ]; then
  rm -f "$tmp_firebase"
  log "    secret unavailable; keeping existing $firebase_file"
else
  rm -f "$tmp_firebase"
  die "no '$FIREBASE_OPTIONS_SECRET' secret and no local $firebase_file.
  lib/main.dart imports it, so the build will not compile without it. Either
  store the file in Secret Manager, or regenerate it with:
      flutterfire configure --project=$GCP_PROJECT"
fi

log ""
log "Done. Build with:"
log "    flutter build apk --dart-define-from-file=config.json"
log "    flutter build ipa --dart-define-from-file=config.json"
