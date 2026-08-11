# Retry mechanism for Flyway CLI download — Design

## Problem

`sanderstad/FlywayCLIInstaller` intermittently fails while fetching the Maven
metadata used to resolve `latest`:

> Failed to retrieve or parse the Maven metadata: ... "The remote server
> returned an error: (403) Forbidden."
> Error: Process completed with exit code 1.

A rerun of the workflow almost always succeeds (see
[issue #1](https://github.com/sanderstad/FlywayCLIInstaller/issues/1)). The
same transient-403 risk applies to the actual CLI archive download, since
both requests hit `download.red-gate.com`. There is currently no retry
logic anywhere in the action.

## Goals

- Retry both network calls to `download.red-gate.com` (metadata fetch and
  archive download) on failure, with a fixed delay between attempts.
- Expose retry count and delay as action inputs so users can tune them,
  with sensible defaults so most users don't need to.
- When retries are exhausted, fail clearly and immediately rather than
  letting a `$null`/empty value silently propagate into a later, more
  confusing failure.

## Non-goals

- Extraction and PATH-update steps are unchanged — they're local
  filesystem operations, not network calls.
- No exponential backoff. A fixed delay is simpler to reason about and
  matches what the issue reporter asked for.

## New action inputs

Added to `action.yml`, alongside the existing `version` input, using the
same kebab-case naming convention:

| Name | Description | Required | Default |
|---|---|---|---|
| `retry-count` | Total number of attempts for a network call (the first try plus retries) | false | `'3'` |
| `retry-delay-seconds` | Fixed delay, in seconds, between attempts | false | `'5'` |

## Changes

### `scripts/Get-LatestFlywayCLIVersion.ps1`

Add two new parameters:

```powershell
[int]$RetryCount = 3
[int]$RetryDelaySeconds = 5
```

Wrap the existing `WebClient.DownloadString` call (currently inside a
single `try/catch`) in a loop that retries up to `$RetryCount` times, with
`Start-Sleep -Seconds $RetryDelaySeconds` between attempts. Each failed
attempt logs a `Write-Warning` with the attempt number and error, so CI
logs show what happened without needing to reproduce the intermittent
failure. If all attempts fail, fall through to the existing
`Write-Error "Failed to retrieve or parse the Maven metadata: ..."` and
`return $null` — behavior unchanged from today, just reached only after
retries are exhausted.

### `action.yml` — "Get Flyway CLI version" step

Pass the new inputs through to the script:

```powershell
$flywayInfo = . ${{GITHUB.ACTION_PATH}}/scripts/Get-LatestFlywayCLIVersion.ps1 -RetryCount ${{ inputs.retry-count }} -RetryDelaySeconds ${{ inputs.retry-delay-seconds }}
```

Add a null check immediately after the call:

```powershell
if ($null -eq $flywayInfo) {
  Write-Error "Failed to retrieve Flyway CLI version information after ${{ inputs.retry-count }} attempts."
  exit 1
}
```

This is a small, targeted fix alongside the retry logic: today, if the
script returns `$null`, `$flywayInfo.LatestVersion` silently evaluates to
`$null`, `flwy_version` gets written as blank, and the workflow fails
later with a confusing 404 on a malformed download URL instead of a clear
message. Adding the check ensures an exhausted-retries failure is reported
where it actually happens.

### `action.yml` — "Download Flyway CLI" step

Wrap the existing `Invoke-WebRequest` call in the same fixed-delay retry
pattern, reading `${{ inputs.retry-count }}` / `${{ inputs.retry-delay-seconds }}`
directly in the inline script (the same way the step already reads
`${{ inputs.version }}` elsewhere in the file):

```powershell
$maxAttempts = [int]"${{ inputs.retry-count }}"
$delaySeconds = [int]"${{ inputs.retry-delay-seconds }}"
$attempt = 0
$success = $false

do {
  $attempt++
  try {
    Invoke-WebRequest -Uri $url -OutFile $outFile
    Write-Host "Downloaded Flyway CLI to $outFile."
    $success = $true
  } catch {
    Write-Warning "Attempt $attempt of $maxAttempts failed: $_"
    if ($attempt -lt $maxAttempts) {
      Start-Sleep -Seconds $delaySeconds
    }
  }
} while (-not $success -and $attempt -lt $maxAttempts)

if (-not $success) {
  Write-Error "Failed to download Flyway CLI after $maxAttempts attempts."
  exit 1
}
```

### `README.md`

- Add `retry-count` and `retry-delay-seconds` to the inputs table with
  their defaults.
- Add a short note under "How it works" that network calls to Red Gate's
  download server are retried on transient failure, and that the behavior
  is configurable via these inputs.

## Testing

This is a composite GitHub Action with no local test harness. Verification
is by:
- Reading through the modified `.ps1` and `action.yml` logic for
  correctness (loop termination, exit codes, variable scoping in the
  composite-action `${{ inputs.* }}` interpolation).
- Optionally, manually invoking `Get-LatestFlywayCLIVersion.ps1` locally
  with a deliberately bad URL to confirm the retry/backoff/failure path
  behaves as expected.
- A real end-to-end check happens on the next tagged release when the
  action runs in an actual workflow.
