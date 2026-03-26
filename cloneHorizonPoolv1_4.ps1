#################################################
##          HORIZON POOL CLONE UTILITY         ##
##      This utility can be used to clone a    ##
##      current VDI Pool to another one        ##
##          Uses the Horizon REST api          ##
##    Created by Matt Heldstab -- 12/31/2025   ##
##          Current version -- 1.4             ##
## 1.1 - Added Functions for Token Check/Auth  ##
## 1.2 - Added ability to modify pool settings ##
## 1.3 - Added Horizon Build lookup to point   ##
##       to the newest Desktop Pools version   ##
##       under /rest/inventory                 ##
## 1.4 - Added option to clone entitlements    ##
#################################################

# Declare Variables

$connectionServer = "https://YOUR-CONNECTION-SERVER-FQDN"
$domain = "YOUR-AD-DOMAIN.local"
$poolNameToClone = "WINPOOL1A" # Example: "WINPOOL1A"
$poolNameToCreate = "WINPOOL1B" # Example: "WINPOOL1B"
$poolNamingConventionToCreate = "WINPOOL1B{n:fixed=2}" # Example: "VMNAME{n:fixed=2}"
$changePoolDisplayName = $true   # $true or $false
$PoolDisplayNameToCreate = "Windows Pool 1B"


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

# Desktop Pools - Key API Endpoint Versions
switch ($horizonVersion) {
    "2512" { $dpVer = "v12" }
    "2506" { $dpVer = "v11" }
    "2503" { $dpVer = "v10" }
    "2412" { $dpVer = "v10" }
    "2406" { $dpVer = "v8"  }
    "2312" { $dpVer = "v8"  }
    "2309" { $dpVer = "v7"  }
    default { $dpVer = "unknown" }
}

# Get all pools
$poolsUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools"
$pools = Invoke-RestMethod -Method GET -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck

# Find the pool to clone
$pool = $pools | Where-Object { $_.name -eq $poolNameToClone }
$poolId = $pool.id

# Get full pool object
$poolUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools/$poolId"
$currentPool = Invoke-RestMethod -Method GET -Uri $poolUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck

# Clone the object
$newPool = $currentPool

# Remove ID so Horizon generates a new one
$newPool.PSObject.Properties.Remove("id")

# Update naming
$newPool.name         = $poolNameToCreate

# Will only run this line if $changePoolDisplayName = $true
if ($changePoolDisplayName -eq $true) {
$newPool.display_name = $poolDisplayNameToCreate
}

# Use established naming pattern declared earlier
$newPool.pattern_naming_settings.naming_pattern = $poolNamingConventionToCreate

write-host "Creating new Omnissa Horizon VDI Pool with the following:" -ForegroundColor Yellow
write-host "Pool Name:" $newpool.name -ForegroundColor Green
write-host "Pool Display Name:" $newpool.display_name -ForegroundColor Green
write-host "Pool OU:" $newpool.customization_settings.ad_container_rdn -ForegroundColor Green
write-host "Pool vCenter Server:" $newpool.vcenter_name -ForegroundColor Green
write-host "Pool Max Desktops:" $newpool.pattern_naming_settings.max_number_of_machines -ForegroundColor Green
write-host "Pool Min Desktops:" $newpool.pattern_naming_settings.min_number_of_machines -ForegroundColor Green
write-host "Pool Spare Desktops:" $newpool.pattern_naming_settings.number_of_spare_machines -ForegroundColor Green
write-host "Pool Naming Convention:" $newpool.pattern_naming_settings.naming_pattern -ForegroundColor Green
write-host "Pool Enabled?" $newpool.enabled -ForegroundColor Green
write-host "Pool Provisioning Enabled?" $newpool.enable_provisioning -ForegroundColor Green


# Ask user if they want to modify pool settings
$modify = Read-Host "Would you like to change (enable/disable) pool or provisioning state? (Y/N)"

if ($modify -match '^(Y|y)$') {

    Write-Host "Modifying pool settings..." -ForegroundColor Cyan

    # Capture original values
    $origpoolenabled         = $newpool.enabled
    $origprovisioningenabled = $newpool.enable_provisioning

    # Prompt user with current values
    $poolenabled = Read-Host "This pool should be enabled (True/False) (currently $origpoolenabled)"
    $provisioningenabled = Read-Host "This pool should have provisioning enabled (True/False) (currently $origprovisioningenabled)"

    # If user hits ENTER, keep original values
    if ([string]::IsNullOrWhiteSpace($poolenabled)) {
        $newpool.enabled = $origpoolenabled
    } else {
        $newpool.enabled = [System.Convert]::ToBoolean($poolenabled)
    }

    if ([string]::IsNullOrWhiteSpace($provisioningenabled)) {
        $newpool.enable_provisioning = $origprovisioningenabled
    } else {
        $newpool.enable_provisioning = [System.Convert]::ToBoolean($provisioningenabled)
    }

    Write-Host "Pool settings updated." -ForegroundColor Green

} else {

    Write-Host "Pool settings will not be modified." -ForegroundColor Yellow
}


$answer = Read-Host "Type Y to continue and clone the pool (anything else will cancel)"

if ($answer -ne 'Y') {
    Write-Host "Aborted."
    exit 1
}

# Create the new pool
$newPoolBody = $newPool | ConvertTo-Json -Depth 20
$newPoolUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools"
$newPoolResult = Invoke-RestMethod -Method POST -Uri $newPoolUri -Headers @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
} -Body $newPoolBody # -SkipCertificateCheck

Write-Host "✔ Completed Pool Clone of: $poolNameToClone -> $poolNameToCreate" -ForegroundColor Green



# Option to clone entitlements from source to cloned pool
$entitlements = Read-Host "Would you like to clone the entitlements from $poolNameToClone to ($poolNameToCreate)? (Y/N)" -ForegroundColor Green

if ($entitlements -match '^(Y|y)$') {

    # Establish Variables
    $poolNameToCloneEntitlements = $poolNameToClone
    $poolNameToCloneEntitlementsTo = $poolNameToCreate  
    
    # Get Entitlements
    # Get all pools
    $poolsUri = "$connectionserver/rest/inventory/$dpVer/desktop-pools"
    $pools = Invoke-RestMethod -Method GET -Uri $poolsUri -Headers @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
    } # -SkipCertificateCheck

    # Find the pool to clone entitlements from
    $pool = $pools | Where-Object { $_.name -eq $poolNameToCloneEntitlements }
    $sourcePoolId = $pool.id

    # Get Entitlement from Source Pool
    $sourcePoolUri = "$connectionServer/rest/entitlements/v1/desktop-pools/$sourcePoolId"
    $sourcePoolEntitlement = Invoke-RestMethod -Method GET -Uri $sourcePoolUri -Headers @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
    } # -SkipCertificateCheck

    # Find the pool to clone entitlements from
    $pool = $pools | Where-Object { $_.name -eq $poolNameToCloneEntitlementsTo }
    $targetPoolId = $pool.id

    $targetPoolEntitlement = [pscustomobject]@{
        id                     = $targetPoolId
        ad_user_or_group_ids   = $sourcePoolEntitlement.ad_user_or_group_ids
    }

    # Apply Entitlement to target pool - Wrapping it with []
    $targetPoolEntitlementBody = ,$targetPoolEntitlement | ConvertTo-Json -Depth 20

    # Wrap with Square Brackets
    $wrappedTargetPoolEntitlementBody = "[`n$targetPoolEntitlementBody`n]"

    # Establish entitlement endpoint object
    $targetPoolUri = "$connectionServer/rest/entitlements/v1/desktop-pools"

    # Build 
    $newEntitlementResult = Invoke-RestMethod -Method POST -Uri $targetPoolUri -Headers @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    } -Body $wrappedTargetPoolEntitlementBody # -SkipCertificateCheck


    Write-Host "Pool entitlements cloned." -ForegroundColor Green

} else {

    Write-Host "Pool entitlements will not be copied." -ForegroundColor Yellow
}


