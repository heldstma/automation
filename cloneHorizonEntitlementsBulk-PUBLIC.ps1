#################################################
##    HORIZON BULK ENTITLEMENTS UTILITY        ##
##   This utility will copy the Horizon       ##
##     Entitlements for multiple VDI Pools     ##
##    and apply them to other pools      ##
##          Uses the Horizon REST api          ##
##    Created by Matt Heldstab -- 03/26/2026   ##
##          Current version -- 1.0             ##
##  1.1 - Added Functions for token validity   ##
##        check, getting a new token if req'd  ##
##  1.2 - Added build check to point to newest ##
##        desktop-pools inventory endpoint     ##       
#################################################

$connectionServer = "https://YOUR-CONNECTION-SERVER-FQDN"
$domain = "YOUR-AD-DOMAIN.local"

# Path to CSV with mappings
# CSV format:
# SourcePool,TargetPool
# WIN2A,WIN2B
# WIN3A,WIN3B

$csvPath = "c:\path-to\cloneHorizonEntitlementsBulk.csv"
$entries = Import-Csv -Path $csvPath

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

# Function to check current Horizon version and change desktop-pools endpoint to the current version
Function Horizon-VersionCheck {

$apiDocsUri = "$connectionserver/rest/v1/api-docs/Default"

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

# Desktop Pools - Key API Endpoint Versions
switch ($horizonVersion) {
    "2512" { $dpVer = "v12" }
    "2506" { $dpVer = "v11" }
    "2503" { $dpVer = "v10" }
    "2412" { $dpVer = "v10" }
    "2406" { $dpVer = "v8"  }
    "2312" { $dpVer = "v8"  }
    "2309" { $dpVer = "v7"  }
    default { $dpVer = "v12" }
}

# Get all pools
$poolsUri = "$connectionserver/rest/inventory/$dpVer/desktop-pools"
$pools = Invoke-RestMethod -Method GET -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

foreach ($entry in $entries) {

    $poolNameToCloneEntitlements    = $entry.SourcePool
    $poolNameToCloneEntitlementsTo  = $entry.TargetPool

    Write-Host "Processing: $poolNameToCloneEntitlements -> $poolNameToCloneEntitlementsTo" -ForegroundColor Cyan

    # --- Find source pool ---
    $sourcePool = $pools | Where-Object { $_.name -eq $poolNameToCloneEntitlements }
    if (-not $sourcePool) {
        Write-Host "Source pool not found: $poolNameToCloneEntitlements" -ForegroundColor Red
        continue
    }
    $sourcePoolId = $sourcePool.id

    # --- Get entitlement from source pool ---
    $sourcePoolUri = "$connectionServer/rest/entitlements/v1/desktop-pools/$sourcePoolId"
    $sourcePoolEntitlement = Invoke-RestMethod -Method GET -Uri $sourcePoolUri -Headers @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
    }

    # --- Find target pool ---
    $targetPool = $pools | Where-Object { $_.name -eq $poolNameToCloneEntitlementsTo }
    if (-not $targetPool) {
        Write-Host "Target pool not found: $poolNameToCloneEntitlementsTo" -ForegroundColor Red
        continue
    }
    $targetPoolId = $targetPool.id

    # --- Build entitlement for target ---
    $targetPoolEntitlement = [pscustomobject]@{
        id                   = $targetPoolId
        ad_user_or_group_ids = $sourcePoolEntitlement.ad_user_or_group_ids
    }

    # Convert to JSON
    $targetPoolEntitlementBody = @($targetPoolEntitlement) | ConvertTo-Json -Depth 20
    
    # Wrap with Square Brackets
    $wrappedTargetPoolEntitlementBody = "[`n$targetPoolEntitlementBody`n]"

    # --- POST entitlement to target pool ---
    $targetPoolUri = "$connectionServer/rest/entitlements/v1/desktop-pools"
    $newEntitlementResult = Invoke-RestMethod -Method POST -Uri $targetPoolUri -Headers @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    } -Body $wrappedTargetPoolEntitlementBody

    Write-Host "✔ Completed: $poolNameToCloneEntitlements -> $poolNameToCloneEntitlementsTo" -ForegroundColor Green
}
