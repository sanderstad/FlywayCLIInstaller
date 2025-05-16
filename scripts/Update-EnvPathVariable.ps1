param(
    [Parameter(Mandatory = $true)]
    [string]$FlywayInstallDirectory
)

function Update-PathVariable {
    param (
        [string]$FlywayInstallDirectory,
        [string]$PreferredTarget = "Machine" # Default target is Machine
    )

    $updateSuccess = $false

    try {
        $currentPath = [System.Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::$PreferredTarget)
        if ($null -ne $currentPath) {
            [System.Environment]::SetEnvironmentVariable('Path', "$FlywayInstallDirectory;$currentPath", [System.EnvironmentVariableTarget]::$PreferredTarget)
            $updateSuccess = $true
            Write-Host "Flyway CLI added to $PreferredTarget Environment Variable PATH successfully."
        }
        else {
            Write-Warning "Unable to retrieve $PreferredTarget PATH. Skipping update."
        }
    }
    catch {
        Write-Warning "Failed to update $PreferredTarget PATH. Error: $_"
        Write-Warning "Elevate Agent/Runner to local admin to set Machine PATH if required"
    }

    if (-not $updateSuccess) {
        try {
            # Fallback to updating User PATH
            [System.Environment]::SetEnvironmentVariable(
                'Path',
                "$FlywayInstallDirectory;$([System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::User))",
                [System.EnvironmentVariableTarget]::User
            )
            $updateSuccess = $true
            Write-Host "Flyway CLI added to User Environment Variable PATH as a fallback."
        }
        catch {
            Write-Error "Failed to update both Machine and User PATH. Error: $_"
        }
    }

    # Refresh PATH in the current session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "User") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "Machine")

    # Return the status of the update
    return $updateSuccess
}

# Call the function to update the PATH variable
$updateResult = Update-PathVariable -FlywayInstallDirectory $FlywayInstallDirectory
if ($updateResult) {
    Write-Host "PATH variable updated successfully."
}
else {
    Write-Host "Failed to update PATH variable."
}