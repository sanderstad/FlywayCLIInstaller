# Retry Mechanism for Flyway CLI Download — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable retry logic (attempt count + fixed delay) around the two network calls to `download.red-gate.com` in the FlywayCLIInstaller action, so transient 403s (see [issue #1](https://github.com/sanderstad/FlywayCLIInstaller/issues/1)) don't fail the whole workflow.

**Architecture:** Two new action inputs (`retry-count`, `retry-delay-seconds`) flow into: (1) `scripts/Get-LatestFlywayCLIVersion.ps1` via new script parameters wrapping its `WebClient.DownloadString` call in a retry loop, and (2) an inline retry loop added directly to the "Download Flyway CLI" step in `action.yml` around `Invoke-WebRequest`. A null-check is added after the version-fetch step so exhausted retries fail immediately with a clear message instead of propagating a blank version downstream.

**Tech Stack:** PowerShell 7 (`pwsh`), composite GitHub Action (`action.yml`). No test framework exists in this repo (no Pester) — verification is manual: PowerShell syntax/tokenizer checks plus running scripts locally against both a valid URL and a deliberately broken URL to observe retry/backoff/failure behavior.

## Global Constraints

- New action inputs use kebab-case, matching the existing `version` input: `retry-count` (default `'3'`), `retry-delay-seconds` (default `'5'`).
- Fixed delay between attempts — no exponential backoff.
- Only the two network calls (metadata fetch, archive download) get retry logic. Extraction and PATH-update steps are untouched (no network I/O).
- `retry-count` is the **total** number of attempts (first try + retries), not "retries in addition to the first try".
- `README.md` is currently saved as UTF-16LE with BOM (confirmed via `file README.md`), which breaks plain-text diffing/editing. Part of this work normalizes it to UTF-8 before editing its content, since it must be touched anyway to document the new inputs.

---

### Task 1: Add retry loop to `scripts/Get-LatestFlywayCLIVersion.ps1`

**Files:**
- Modify: `scripts/Get-LatestFlywayCLIVersion.ps1`

**Interfaces:**
- Produces: script now accepts `-RetryCount <int>` (default `3`) and `-RetryDelaySeconds <int>` (default `5`) in addition to the existing `-MetadataUrl <string>`. Behavior on exhausted retries is unchanged from today (`Write-Error` + `return $null` / script returns `$null`), just reached only after `RetryCount` attempts.

- [ ] **Step 1: Replace the top-level `param()` block**

Current (lines 1-4):
```powershell
param(
    [Parameter(Mandatory = $false)]
    [string]$MetadataUrl = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/maven-metadata.xml"
)
```

Replace with:
```powershell
param(
    [Parameter(Mandatory = $false)]
    [string]$MetadataUrl = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/maven-metadata.xml",

    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 3,

    [Parameter(Mandatory = $false)]
    [int]$RetryDelaySeconds = 5
)
```

- [ ] **Step 2: Replace the function's `param()` block**

Current (lines 8-11):
```powershell
    param(
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl
    )
```

Replace with:
```powershell
    param(
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl,

        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 3,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelaySeconds = 5
    )
```

- [ ] **Step 3: Wrap the metadata download in a retry loop, separate from XML-parsing errors**

Current (lines 13-58):
```powershell
    try {
        # Download the maven-metadata.xml file
        $webClient = New-Object System.Net.WebClient
        $metadataXml = $webClient.DownloadString($MetadataUrl)

        # Load the XML content
        $metadata = [xml]$metadataXml

        # Get the latest version from the versioning/release element
        $latestVersion = $metadata.metadata.versioning.release

        # Get the lastUpdated timestamp (in yyyyMMddHHmmss format)
        $lastUpdatedTimestamp = $metadata.metadata.versioning.lastUpdated

        # Convert the lastUpdated timestamp to a more readable format
        $lastUpdatedDateTime = $null
        if ($lastUpdatedTimestamp -match '^\d{14}$') {
            $year = $lastUpdatedTimestamp.Substring(0, 4)
            $month = $lastUpdatedTimestamp.Substring(4, 2)
            $day = $lastUpdatedTimestamp.Substring(6, 2)
            $hour = $lastUpdatedTimestamp.Substring(8, 2)
            $minute = $lastUpdatedTimestamp.Substring(10, 2)
            $second = $lastUpdatedTimestamp.Substring(12, 2)

            $lastUpdatedDateTime = Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second $second
        }

        # Get all available versions
        $allVersions = $metadata.metadata.versioning.versions.version

        # Create a custom object with the version information
        $result = [PSCustomObject]@{
            Url                 = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/"
            LatestVersion       = $latestVersion
            LatestVersionUrl    = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/$latestVersion/"
            LastUpdated         = $lastUpdatedTimestamp
            LastUpdatedDateTime = $lastUpdatedDateTime
            AllVersions         = $allVersions
        }

        return $result
    }
    catch {
        Write-Error "Failed to retrieve or parse the Maven metadata: $_"
        return $null
    }
```

Replace with:
```powershell
    $metadataXml = $null
    $attempt = 0

    while ($attempt -lt $RetryCount -and $null -eq $metadataXml) {
        $attempt++
        try {
            $webClient = New-Object System.Net.WebClient
            $metadataXml = $webClient.DownloadString($MetadataUrl)
        }
        catch {
            Write-Warning "Attempt $attempt of $RetryCount to download Maven metadata failed: $_"
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    if ($null -eq $metadataXml) {
        Write-Error "Failed to retrieve or parse the Maven metadata after $RetryCount attempts."
        return $null
    }

    try {
        # Load the XML content
        $metadata = [xml]$metadataXml

        # Get the latest version from the versioning/release element
        $latestVersion = $metadata.metadata.versioning.release

        # Get the lastUpdated timestamp (in yyyyMMddHHmmss format)
        $lastUpdatedTimestamp = $metadata.metadata.versioning.lastUpdated

        # Convert the lastUpdated timestamp to a more readable format
        $lastUpdatedDateTime = $null
        if ($lastUpdatedTimestamp -match '^\d{14}$') {
            $year = $lastUpdatedTimestamp.Substring(0, 4)
            $month = $lastUpdatedTimestamp.Substring(4, 2)
            $day = $lastUpdatedTimestamp.Substring(6, 2)
            $hour = $lastUpdatedTimestamp.Substring(8, 2)
            $minute = $lastUpdatedTimestamp.Substring(10, 2)
            $second = $lastUpdatedTimestamp.Substring(12, 2)

            $lastUpdatedDateTime = Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second $second
        }

        # Get all available versions
        $allVersions = $metadata.metadata.versioning.versions.version

        # Create a custom object with the version information
        $result = [PSCustomObject]@{
            Url                 = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/"
            LatestVersion       = $latestVersion
            LatestVersionUrl    = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/$latestVersion/"
            LastUpdated         = $lastUpdatedTimestamp
            LastUpdatedDateTime = $lastUpdatedDateTime
            AllVersions         = $allVersions
        }

        return $result
    }
    catch {
        Write-Error "Failed to retrieve or parse the Maven metadata: $_"
        return $null
    }
```

- [ ] **Step 4: Update the trailing invocation line**

Current (line 61):
```powershell
Get-LatestFlywayCLIVersion -MetadataUrl $MetadataUrl
```

Replace with:
```powershell
Get-LatestFlywayCLIVersion -MetadataUrl $MetadataUrl -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
```

- [ ] **Step 5: Verify syntax is valid**

Run:
```powershell
pwsh -NoProfile -Command "$errors = $null; [System.Management.Automation.Language.Parser]::ParseFile('scripts/Get-LatestFlywayCLIVersion.ps1', [ref]$null, [ref]$errors); if ($errors) { $errors } else { 'OK' }"
```
Expected: `OK`

- [ ] **Step 6: Verify the failure/retry path against a bad URL**

Run:
```powershell
pwsh -NoProfile -File scripts/Get-LatestFlywayCLIVersion.ps1 -MetadataUrl "https://download.red-gate.com/does-not-exist.xml" -RetryCount 3 -RetryDelaySeconds 2
```
Expected: three `WARNING: Attempt N of 3 to download Maven metadata failed: ...` lines roughly 2 seconds apart, then `Failed to retrieve or parse the Maven metadata after 3 attempts.`, script prints nothing else (returns `$null`). Total wall time roughly 4-6 seconds (two delays between three attempts).

- [ ] **Step 7: Verify the success path is unaffected**

Run:
```powershell
pwsh -NoProfile -File scripts/Get-LatestFlywayCLIVersion.ps1
```
Expected: prints the `PSCustomObject` with `Url`, `LatestVersion`, `LatestVersionUrl`, `LastUpdated`, `LastUpdatedDateTime`, `AllVersions` populated, same as before this change, with no warnings.

- [ ] **Step 8: Commit**

```bash
git add scripts/Get-LatestFlywayCLIVersion.ps1
git commit -m "Add retry loop to Flyway metadata fetch"
```

---

### Task 2: Add `retry-count` / `retry-delay-seconds` inputs and wire them into the version-fetch step

**Files:**
- Modify: `action.yml`

**Interfaces:**
- Consumes: `Get-LatestFlywayCLIVersion.ps1 -RetryCount <int> -RetryDelaySeconds <int>` from Task 1.
- Produces: `${{ inputs.retry-count }}` and `${{ inputs.retry-delay-seconds }}` available to every step in the composite action (consumed by Task 3).

- [ ] **Step 1: Add the two new inputs**

Current (lines 8-12):
```yaml
inputs:
  version:
    description: 'The version of Flyway to install'
    required: false
    default: 'latest'
```

Replace with:
```yaml
inputs:
  version:
    description: 'The version of Flyway to install'
    required: false
    default: 'latest'
  retry-count:
    description: 'Number of attempts for network calls to Red Gate (metadata fetch and CLI download) before failing'
    required: false
    default: '3'
  retry-delay-seconds:
    description: 'Delay in seconds between retry attempts for network calls'
    required: false
    default: '5'
```

- [ ] **Step 2: Pass the inputs into the version-fetch script call and add a null-check**

Current (the "Get Flyway CLI version" step run block):
```yaml
        $flywayInfo = . ${{GITHUB.ACTION_PATH}}/scripts/Get-LatestFlywayCLIVersion.ps1

        $flywayInfo

        if("${{inputs.version}}" -eq 'latest') {
```

Replace with:
```yaml
        $flywayInfo = . ${{GITHUB.ACTION_PATH}}/scripts/Get-LatestFlywayCLIVersion.ps1 -RetryCount ${{ inputs.retry-count }} -RetryDelaySeconds ${{ inputs.retry-delay-seconds }}

        if ($null -eq $flywayInfo) {
          Write-Error "Failed to retrieve Flyway CLI version information after ${{ inputs.retry-count }} attempts."
          exit 1
        }

        $flywayInfo

        if("${{inputs.version}}" -eq 'latest') {
```

- [ ] **Step 3: Verify the edited run block is syntactically valid PowerShell**

The `run:` block is plain PowerShell text embedded in YAML. Extract it and parse it standalone:

```powershell
pwsh -NoProfile -Command @'
$yaml = Get-Content action.yml -Raw
if ($yaml -match "(?ms)^\s*- name: .Get Flyway CLI version.\r?\n\s*shell: pwsh\r?\n\s*run: \|\r?\n((?:.*\r?\n)*?)(?=\s*- name:)") {
  $script = $Matches[1]
  Set-Content -Path "$env:TEMP\verify-step.ps1" -Value $script
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile("$env:TEMP\verify-step.ps1", [ref]$null, [ref]$errors)
  if ($errors) { $errors } else { "OK" }
} else {
  "Could not locate step block"
}
'@
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add action.yml
git commit -m "Add retry-count and retry-delay-seconds inputs, wire into version fetch"
```

---

### Task 3: Add retry loop to the "Download Flyway CLI" step

**Files:**
- Modify: `action.yml`

**Interfaces:**
- Consumes: `${{ inputs.retry-count }}` and `${{ inputs.retry-delay-seconds }}` from Task 2.

- [ ] **Step 1: Replace the download step's `try`/`catch` with a retry loop**

Current:
```yaml
    - name: Download Flyway CLI
      shell: pwsh
      run: |
        $fileName = $env:flwy_filename
        $url = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/$($env:flwy_version)/$fileName"
        $tempPath = $env:RUNNER_TEMP

        if (-not (Test-Path $tempPath)) {
          New-Item -ItemType Directory -Path $tempPath
        }

        $outFile = Join-Path $tempPath $fileName

        try {
          Invoke-WebRequest -Uri $url -OutFile $outFile
          Write-Host "Downloaded Flyway CLI to $outFile."
        } catch {
          Write-Error "Failed to download Flyway CLI: $_"
          exit 1
        }
```

Replace with:
```yaml
    - name: Download Flyway CLI
      shell: pwsh
      run: |
        $fileName = $env:flwy_filename
        $url = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/$($env:flwy_version)/$fileName"
        $tempPath = $env:RUNNER_TEMP

        if (-not (Test-Path $tempPath)) {
          New-Item -ItemType Directory -Path $tempPath
        }

        $outFile = Join-Path $tempPath $fileName

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
            Write-Warning "Attempt $attempt of $maxAttempts to download Flyway CLI failed: $_"
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

- [ ] **Step 2: Verify the retry loop logic standalone**

Extract just the new loop and drive it with a mock function that fails twice then succeeds, to confirm attempt counting, warning messages, and delay behavior without depending on network conditions:

```powershell
pwsh -NoProfile -Command @'
$maxAttempts = 3
$delaySeconds = 1
$attempt = 0
$success = $false
$callCount = 0

function Invoke-Mock {
  $script:callCount++
  if ($script:callCount -lt 3) { throw "simulated failure $script:callCount" }
}

do {
  $attempt++
  try {
    Invoke-Mock
    Write-Host "Downloaded Flyway CLI to (mock)."
    $success = $true
  } catch {
    Write-Warning "Attempt $attempt of $maxAttempts to download Flyway CLI failed: $_"
    if ($attempt -lt $maxAttempts) {
      Start-Sleep -Seconds $delaySeconds
    }
  }
} while (-not $success -and $attempt -lt $maxAttempts)

if (-not $success) {
  Write-Error "Failed to download Flyway CLI after $maxAttempts attempts."
  exit 1
}

"Final attempt count: $attempt, success: $success"
'@
```
Expected: two `WARNING: Attempt N of 3 ...` lines, then `Downloaded Flyway CLI to (mock).`, then `Final attempt count: 3, success: True`.

- [ ] **Step 3: Verify the edited YAML step is syntactically valid PowerShell**

Same extraction technique as Task 2 Step 3, targeting `- name: Download Flyway CLI` instead:
```powershell
pwsh -NoProfile -Command @'
$yaml = Get-Content action.yml -Raw
if ($yaml -match "(?ms)^\s*- name: Download Flyway CLI\r?\n\s*shell: pwsh\r?\n\s*run: \|\r?\n((?:.*\r?\n)*?)(?=\s*- name:)") {
  $script = $Matches[1]
  Set-Content -Path "$env:TEMP\verify-download-step.ps1" -Value $script
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile("$env:TEMP\verify-download-step.ps1", [ref]$null, [ref]$errors)
  if ($errors) { $errors } else { "OK" }
} else {
  "Could not locate step block"
}
'@
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add action.yml
git commit -m "Add retry loop to Flyway CLI archive download"
```

---

### Task 4: Normalize `README.md` encoding and document the new inputs

**Files:**
- Modify: `README.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Convert `README.md` from UTF-16LE to UTF-8**

`file README.md` currently reports `Unicode text, UTF-16, little-endian text, with CRLF line terminators`, which is why reading it with plain-text tools mangles it. Convert in place before editing content:

```powershell
$content = [System.IO.File]::ReadAllText("README.md", [System.Text.Encoding]::Unicode)
[System.IO.File]::WriteAllText("README.md", $content, (New-Object System.Text.UTF8Encoding($false)))
```

Verify:
```bash
file README.md
```
Expected: `README.md: ASCII text` (or `UTF-8 Unicode text`), no longer reporting UTF-16.

- [ ] **Step 2: Add the new inputs to the Inputs table**

Current:
```markdown
## Inputs

| Name    | Description                       | Required | Default  |
|---------|-----------------------------------|----------|----------|
| version | Flyway CLI version to install     | false    | latest   |
```

Replace with:
```markdown
## Inputs

| Name                 | Description                                                                          | Required | Default |
|----------------------|---------------------------------------------------------------------------------------|----------|---------|
| version              | Flyway CLI version to install                                                        | false    | latest  |
| retry-count          | Number of attempts for network calls to Red Gate (metadata fetch and CLI download)  | false    | 3       |
| retry-delay-seconds  | Delay in seconds between retry attempts for network calls                           | false    | 5       |
```

- [ ] **Step 3: Add a retry note under "How it works"**

Current:
```markdown
## How it works

1. **Detects OS** and sets the correct download filename.
2. **Downloads** the Flyway CLI archive from the official source.
3. **Extracts** the archive to a local directory.
4. **Adds Flyway to PATH** so it can be used in subsequent workflow steps.
5. **Validates** the installation by running the version command.
```

Replace with:
```markdown
## How it works

1. **Detects OS** and sets the correct download filename.
2. **Downloads** the Flyway CLI archive from the official source, retrying on transient failures (see `retry-count` / `retry-delay-seconds` above).
3. **Extracts** the archive to a local directory.
4. **Adds Flyway to PATH** so it can be used in subsequent workflow steps.
5. **Validates** the installation by running the version command.

Network calls to Red Gate's download server (both the version-metadata lookup and the archive download) are retried up to `retry-count` times, `retry-delay-seconds` apart, before the action fails. This helps with intermittent `403` responses from the server.
```

- [ ] **Step 4: Verify the file reads cleanly**

```bash
cat README.md
```
Expected: full readable Markdown (no mangled spacing), including the updated Inputs table and How it works section.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document retry-count and retry-delay-seconds inputs; fix README encoding"
```

---

## Final Verification

- [ ] Re-read the full `action.yml` end to end and confirm indentation is consistent YAML (no tabs, consistent step-list indentation) — a broken indent here fails the whole composite action at parse time, not at the failing step.
- [ ] Confirm `git log --oneline -5` shows four new commits, one per task, on top of the design-doc commit.
- [ ] Push the branch and open/update the PR referencing issue #1, noting the two new inputs and their defaults so a reviewer can sanity-check the naming.
