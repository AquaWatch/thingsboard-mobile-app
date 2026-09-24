#!/usr/bin/env bash
#
# Pulls the SWIM-OS mobile build configuration out of Google Secret Manager and
# writes config.json, the dart-defines file consumed via --dart-define-from-file.
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
# -----------------------------------------------------------------------------

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config_file="config.json"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v gcloud >/dev/null 2>&1 \
  || die "gcloud not found on PATH. Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install"

# Probe by executing, not by presence on PATH: on Windows, `python3` is often a
# Microsoft Store "app execution alias" that resolves but cannot run. Check the
# major version too, since `python` is still Python 2 on some machines and the
# snippet below uses Python 3 only syntax.
python_bin=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 \
     && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    python_bin="$candidate"
    break
  fi
done
[ -n "$python_bin" ] || die "Python 3 is required to validate $config_file"

access_secret() {
  # access_secret <secret-id> <version> -> secret payload on stdout
  gcloud secrets versions access "$2" --secret="$1" --project="$GCP_PROJECT"
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

# Validate and normalise in one pass, while the payload is still in the temp file
# the trap covers: reject anything that is not JSON, and strip a UTF-8 BOM, which
# flutter cannot parse in --dart-define-from-file.
"$python_bin" - "$tmp_config" <<'PY' || die "secret '$CONFIG_SECRET' is not valid JSON"
import io, json, sys

path = sys.argv[1]
text = io.open(path, encoding='utf-8-sig', newline='').read()
json.loads(text)
text = text.replace('\r\n', '\n').replace('\r', '\n').rstrip('\n') + '\n'
io.open(path, 'w', encoding='utf-8', newline='').write(text)
PY

mv "$tmp_config" "$config_file"
trap - EXIT
log "    wrote $config_file"

log ""
log "Done. Build with:"
log "    flutter build apk --dart-define-from-file=config.json"
log "    flutter build ipa --dart-define-from-file=config.json"
