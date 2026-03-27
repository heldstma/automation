#################################################
##             POOL ENABLE SCRIPT              ##
##      This utility can be used to enable     ##
##      a pool and provisioning in Horizon     ##
##          Uses the Horizon RESTapi           ##
##    Created by Matt Heldstab -- 03/26/2026   ##
##          Current version -- 1.0             ##
#################################################

$connectionServer = "https://YOUR-CONNECTION-SERVER-FQDN"
$domain = "YOUR-AD-DOMAIN.local"
$poolNameToModify = "WINPOOL1" # Enter pool name here

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

# Get Entitlements
# Get all pools
$poolsUri = "$connectionserver/rest/inventory/$dpVer/desktop-pools"
$pools = Invoke-RestMethod -Method GET -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck

# Find the poolID to enable
$pool = $pools | Where-Object { $_.name -eq $poolNameToEnable }
$sourcePoolId = $pool.id


# Enable Provisioning and the Pool
$poolenabled = $true
$provisioningenabled = $true

# Convert to Boolean
$pool.enable_provisioning = [System.Convert]::ToBoolean($provisioningenabled)
$pool.enabled = [System.Convert]::ToBoolean($poolenabled)

# Show new settings to the user before applying the change
Write-Host "Current settings after enabling provisioning and the pool"
Write-Host "Max Number of Machines: " $pool.pattern_naming_settings.max_number_of_machines
Write-Host "Min Number of Machines: " $pool.pattern_naming_settings.min_number_of_machines
Write-Host "Number of Spare Machines: " $pool.pattern_naming_settings.number_of_spare_machines
Write-Host "Pool Enabled: " $pool.enabled
Write-Host "Provisioning Enabled: " $pool.enable_provisioning

$updateUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools/$sourcePoolId"
$body = $pool | ConvertTo-Json -Depth 20

try {
    Invoke-RestMethod -Method Put -Uri $updateUri -Headers @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
    } -Body $body -SkipCertificateCheck

    Write-Host "`nPool enabled successfully!" -ForegroundColor Green
}
catch {
    Write-Host "`nPool update FAILED!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor DarkRed
}
