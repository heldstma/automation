#################################################
##   POOL JSON EXPORT SCRIPT-Omnissa Horizon   ##
##      This utility can be used to export     ##
##  config settings for all VDI Pools to JSON  ##
##          Uses the Horizon RESTapi           ##
##     Does not back up entitlements           ##
##    Created by Matt Heldstab -- 11/22/2025   ##
##          Current version -- 1.1 - 3/26/2026 ##
## 1.1 - Added prompt for export path          ##
#################################################

$connectionServer = "https://YOUR-CONNECTION-SERVER-FQDN"
$domain = "YOUR-AD-DOMAIN.local"

# Function to check for a valid Horizon REST API token
function Token-ExpiryCheck {

    # If token is null, empty, or whitespace — skip the check entirely
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "No token found — skipping expiration check." -ForegroundColor Yellow
        return $null
    }

    try {
        $tokenParts = $token.Split('.')

        $decodedPayload = [System.Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($tokenParts[1])
        )

        $decodedPayloadObj = $decodedPayload | ConvertFrom-Json
        $expirationTimestamp = $decodedPayloadObj.exp

        $expirationTime = [DateTimeOffset]::FromUnixTimeSeconds($expirationTimestamp).UtcDateTime

        Write-Host "Token expires at: $expirationTime"
        return $expirationTime
    }
    catch {
        Write-Host "Token is invalid or unreadable — skipping expiration check." -ForegroundColor Yellow
        return $null
    }
}

# Function to get a new Horizon API Token
function Get-HorizonToken {

    Write-Host "Token invalid - Re-authenticating" -ForegroundColor Yellow

    # Prompt for Horizon admin credentials
    $creds = Get-Credential -Message "Enter Horizon admin credentials"

    # Extract username + password
    $username = $creds.UserName
    $password = $creds.GetNetworkCredential().Password

    # If user typed DOMAIN\username, split it
    if ($username -match "\\") {
        $domain, $username = $username -split "\\", 2
    }

    # Build authentication URI
    $authUri = "$connectionServer/rest/login"

    # Build JSON body
    $body = @{
        username = $username
        password = $password
        domain   = $domain
    } | ConvertTo-Json

    # Send authentication request
    $response = Invoke-RestMethod -Method Post -Uri $authUri `
        -Body $body `
        -ContentType "application/json"
        # -SkipCertificateCheck

    # Extract token
    $token = $response.access_token

    Write-Host "Authenticating to " $authUri

    return $token
}

Function Horizon-VersionCheck {

$apiDocsUri = "$connectionServer/rest/v1/api-docs/Default"

$headers = @{
    Authorization = "Bearer $token"
  }

  $apiDocs = Invoke-RestMethod -Method GET -Uri $apiDocsUri -Headers $headers
$version = $apiDocs.info.version
return $version
}

$horizonVersion = Horizon-VersionCheck
Write-host $horizonVersion


Write-Host "Current UTC Time:" (Get-Date).ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss")
$tokenExpirationTime = Token-ExpiryCheck


if ($tokenExpirationTime -gt (Get-Date -AsUTC)) {
    $tokenStatus = $true
} else {
    $token = Get-HorizonToken
    $tokenExpirationTime = Token-ExpiryCheck
}

# Desktop Pools - Key API Endpoint Versions - Defaults to v12 if version is not found to support future versions of Horizon
switch ($horizonVersion) {
#    "NEXT" { $dpVer = "vNEXT"}
    "2512" { $dpVer = "v12" }
    "2506" { $dpVer = "v11" }
    "2503" { $dpVer = "v10" }
    "2412" { $dpVer = "v10" }
    "2406" { $dpVer = "v8"  }
    "2312" { $dpVer = "v8"  }
    "2309" { $dpVer = "v7"  }
    default { $dpVer = "v12" }
}


# Default export path (script directory)
$defaultExportPath = $PSScriptRoot

# Prompt user (ENTER accepts default)
$exportPath = Read-Host "Enter export path for Horizon pool JSON files [Press ENTER for '$defaultExportPath']"

# If user pressed ENTER, use default
if ([string]::IsNullOrWhiteSpace($exportPath)) {
    $exportPath = $defaultExportPath
}

# Expand environment variables
$exportPath = [Environment]::ExpandEnvironmentVariables($exportPath)

# Validate / create directory
if (-not (Test-Path -Path $exportPath)) {
    try {
        New-Item -ItemType Directory -Path $exportPath -Force | Out-Null
        Write-Host "Created directory: $exportPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create directory: $exportPath"
        return
    }
}

Write-Host "Exporting Horizon pools to: $exportPath" -ForegroundColor Cyan

$poolsUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools"
$pools = Invoke-RestMethod -Method Get -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} -SkipCertificateCheck

foreach ($pool in $pools) {
    $poolId   = $pool.id
    $poolName = $pool.name.Replace(" ", "_")   # clean filename

    $pool | ConvertTo-Json -Depth 10 | Out-File "$exportPath\$poolName.json"
}

