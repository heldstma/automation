#################################################
##        HORIZON POOL DISABLE/TRIM UTILITY    ##
##      This utility will allow the user to    ##
##    disable a pool, disable provisioning     ##
##      and delete all VMs in the pool         ##
##          Uses the Horizon REST api          ##
##    Created by Matt Heldstab -- 03/26/2026   ##
##          Current version -- 1.0             ##
#################################################

$connectionServer = "https://YOUR-CONNECTION-SERVER-FQDN"
$domain = "YOUR-AD-DOMAIN.local"
$poolNameToModify = "WINPOOL1" # Enter pool name here

# Function to check for a valid Horizon REST API token
function Get-TokenExpiry {

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
Function Get-HorizonVersion {

$apiDocsUri = "$connectionserver/rest/v1/api-docs/Default"

$headers = @{
    Authorization = "Bearer $token"
  }

  $apiDocs = Invoke-RestMethod -Method GET -Uri $apiDocsUri -Headers $headers
$version = $apiDocs.info.version
return $version
}

$horizonVersion = Get-HorizonVersion
Write-host $horizonVersion


Write-Host "Current UTC Time:" (Get-Date).ToUniversalTime().ToString("MM/dd/yyyy HH:mm:ss")
$tokenExpirationTime = Get-TokenExpiry


if ($tokenExpirationTime -gt (Get-Date -AsUTC)) {
    $tokenStatus = $true
} else {
    $token = Get-HorizonToken
    $tokenExpirationTime = Get-TokenExpiry
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
$poolsUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools"
$pools = Invoke-RestMethod -Method GET -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck

# Find the pool to modify
$pool = $pools | Where-Object { $_.name -eq $poolNameToModify }
$poolId = $pool.id

# Ask user if they want to modify pool settings
$modify = Read-Host "Would you like to change (enable/disable) pool or provisioning state? (Y/N)"

if ($modify -match '^(Y|y)$') {

    # ---- GET FULL POOL JSON USING ID ----

    $poolUri = "$connectionServer/rest/inventory/$dpVer/desktop-pools/$poolId"
    $poolJson = Invoke-RestMethod -Method Get -Uri $poolUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
    } -SkipCertificateCheck

    
    # ---- MODIFY THE JSON ----
    # EDIT HERE: This is where you make your changes to the pool JSON

    $updated = $poolJson | ConvertTo-Json -Depth 20 | ConvertFrom-Json

    ### Capture original values in a variable to show the user
    $origpoolenabled = $pooljson.enabled
    $origprovisioningenabled = $pooljson.enable_provisioning

    ### Prompt the user for a new value and show them the current value
    $poolenabled = Read-Host "This pool should be enabled (True/False) (currently $origpoolenabled)"
    $provisioningenabled = Read-Host "This pool should have provisioning enabled (True/False) (currently $origprovisioningenabled)"

    ### Convert values to integers or boolean
    $updated.enable_provisioning = [System.Convert]::ToBoolean($provisioningenabled)
    $updated.enabled = [System.Convert]::ToBoolean($poolenabled)

    $updateUri = "$connectionServer/rest/inventory/v10/desktop-pools/$poolId"
    $body = $updated | ConvertTo-Json -Depth 20

    try {
        Invoke-RestMethod -Method Put -Uri $updateUri -Headers @{
            "Authorization" = "Bearer $token"
            "Accept"        = "application/json"
            "Content-Type"  = "application/json"
        } -Body $body -SkipCertificateCheck

        Write-Host "`nPool updated successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "`nPool update FAILED!" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
    }

    Write-Host "Pool settings updated." -ForegroundColor Green

} else {

    Write-Host "Pool settings will not be modified." -ForegroundColor Yellow
}


# Get all machines
$machinesUri = "$connectionServer/rest/inventory/v10/machines"
$machines = Invoke-RestMethod -Method Get -Uri $machinesUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
    } -SkipCertificateCheck

# Filter machines that are AVAILABLE and are in the pool we identified
$machinesToDelete = $machines |
    Where-Object {
        $_.state -eq "AVAILABLE" -and
        $_.desktop_pool_name -eq $poolNameToModify
    }

# Check to see if any machines were found before attempting to delete
if ($machinesToDelete.Count -gt 0) {

    # Convert to JSON
    $machinesToDeleteBody = @($machinesToDelete) | ConvertTo-Json -Depth 20
    
    # Establish delete machine endpoint URI
    $deleteMachineUri = "$connectionServer/rest/inventory/v10/machines"

    # Create an array containing mandatory machine delete data and the machine IDs of systems to delete
    $payload = @{
        machine_delete_data = @{
            allow_delete_from_multi_desktop_pools = $true
            archive_persistent_disk               = $false
            delete_from_disk                      = $true
            force_logoff_session                  = $false
        }
        machine_ids = $machinesToDelete.id
    } | ConvertTo-Json -Depth 5

    $deleteMachines = Invoke-RestMethod -Method DELETE -Uri $deleteMachineUri -Headers @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    } -Body $payload

    write-host "These machines will be deleted:" -ForegroundColor Green
    $machinesToDelete | Select-Object name, desktop_pool_name | Format-Table -AutoSize

}
else {
    Write-Host "No machines found."
}

    

