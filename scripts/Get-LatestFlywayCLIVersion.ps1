param(
    [Parameter(Mandatory = $false)]
    [string]$MetadataUrl = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/maven-metadata.xml",

    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 3,

    [Parameter(Mandatory = $false)]
    [int]$RetryDelaySeconds = 5
)

function Get-LatestFlywayCLIVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl,

        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 3,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelaySeconds = 5
    )

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
}

Get-LatestFlywayCLIVersion -MetadataUrl $MetadataUrl -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds