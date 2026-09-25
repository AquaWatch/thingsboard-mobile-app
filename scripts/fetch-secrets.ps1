<#
.SYNOPSIS
    Pulls the SWIM-OS mobile build configuration out of Google Secret Manager.

.DESCRIPTION
    Windows counterpart to scripts/fetch-secrets.sh. Writes configs.json, the
    dart-defines file consumed via --dart-define-from-file, which is
    deliberately kept out of git.

.EXAMPLE
    .\scripts\fetch-secrets.ps1

.EXAMPLE
    .\scripts\fetch-secrets.ps1 -ConfigSecret some-other-secret-id
#>
[CmdletBinding()]
param(
    # Secret Manager coordinates (ENG-245). Secret IDs may only contain
    # [A-Za-z0-9_-]; there is no literal "configs.json" secret.
    [string]$GcpProject                    = $(if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { 'riverwatch-be1e4' }),
    [string]$ConfigSecret                  = $(if ($env:CONFIG_SECRET) { $env:CONFIG_SECRET } else { 'SWIM-OS-MOBILE-CONFIGS-JSON' }),
    [string]$ConfigSecretVersion           = $(if ($env:CONFIG_SECRET_VERSION) { $env:CONFIG_SECRET_VERSION } else { 'latest' })
)

$ErrorActionPreference = 'Stop'

# Native command output is decoded with [Console]::OutputEncoding, which defaults
# to the OEM codepage in Windows PowerShell 5.1 and corrupts every non-ASCII byte.
# The bash twin sidesteps this by redirecting raw bytes to a file.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot          = Split-Path -Parent $PSScriptRoot
$configFile        = Join-Path $repoRoot 'configs.json'
$entitlementsFile  = Join-Path $repoRoot 'ios\Runner\Runner.entitlements'

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    throw 'gcloud not found on PATH. Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install'
}

function Get-Secret {
    param([string]$Name, [string]$Version)

    # gcloud is a .cmd shim; capture stdout and let a non-zero exit mean "no access".
    $gcloudArgs = @('secrets', 'versions', 'access', $Version, "--secret=$Name", "--project=$GcpProject")

    $payload = & gcloud @gcloudArgs
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($payload -is [array]) { $payload = $payload -join "`n" }
    if ([string]::IsNullOrWhiteSpace($payload)) { return $null }
    return $payload
}

function Write-Utf8Lf {
    # LF endings, exactly one trailing newline, no BOM. Keeps this script and
    # its bash twin byte-identical, so switching between them is not a diff.
    param([string]$Path, [string]$Text)

    $normalized = $Text.TrimStart([char]0xFEFF)
    $normalized = $normalized -replace "`r`n", "`n" -replace "`r", "`n"
    $normalized = $normalized.TrimEnd("`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

# --- configs.json ------------------------------------------------------------
Write-Host "==> Fetching ${ConfigSecret}:${ConfigSecretVersion} from $GcpProject"
$configJson = Get-Secret -Name $ConfigSecret -Version $ConfigSecretVersion
if ($null -eq $configJson) {
    throw @"
could not read secret '$ConfigSecret' from project '$GcpProject'.
  - Confirm the secret ID (pass -ConfigSecret <id> to override).
  - Confirm you are logged in:  gcloud auth application-default login
  - Confirm you hold roles/secretmanager.secretAccessor on the secret.
"@
}

try { $config = $configJson | ConvertFrom-Json }
catch { throw "secret '$ConfigSecret' is not valid JSON: $_" }

# Associated domains must be literal, so Runner.entitlements cannot read
# appLinksUrlHost. Assert the two agree: otherwise a config change takes effect
# on Android and silently leaves iOS universal links pointing at the old domain.
if ($config.appLinksUrlHost) {
    if (-not (Test-Path $entitlementsFile)) { throw "cannot read $entitlementsFile" }
    $declared = [regex]::Matches((Get-Content -Raw $entitlementsFile), 'applinks:([^<\s]+)') |
        ForEach-Object { $_.Groups[1].Value }
    if ($declared -notcontains $config.appLinksUrlHost) {
        $found = if ($declared) { $declared -join ', ' } else { '(none)' }
        throw @"
appLinksUrlHost is not declared in $entitlementsFile.
  configs.json:  $($config.appLinksUrlHost)
  entitlements:  $found
"@
    }
}

Write-Utf8Lf -Path $configFile -Text $configJson
Write-Host "    wrote $configFile"

Write-Host ''
Write-Host 'Done. Build with:'
Write-Host '    flutter build apk --dart-define-from-file=configs.json'
Write-Host '    flutter build ipa --dart-define-from-file=configs.json'
