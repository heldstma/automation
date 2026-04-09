#################################################
##   POOL PUSH IMAGE SCRIPT-Omnissa Horizon   ##
##      This utility can be used to            ##
##     push a new image to a VDI pool          ##
##    Uses the Horizon RESTapi and PowerCLI    ##
##    Created by Matt Heldstab -- 1/23/2026    ##
##          Current version -- 1.1 2/13/2026   ##
#################################################
##  Changelog                                  ##
##  1.1 - Updated desktop-pools to v12         ##
##        Added check for active connections   ##
##        Modified Token Validation method     ##
#################################################


$connectionServer = "https://vconn1.domain.com"
$poolsUri = "$connectionServer/rest/inventory/v12/desktop-pools"
$vCenterServer = "vcen.domain.com"

# ==============================
# CONFIGURATION
# ==============================

# Horizon Objects
# Current Pools

$DesktopPoolName = "WIN1B"

$cpuCoresPerSocket = 2
$cpusTotal = 2
#$cpuCoresPerSocket = 4
#$cpusTotal = 4

# Only Un-remark one of these three
$memTotalinmb = 8172      # 32GB = 32768; 16GB = 16384; 12GB = 12288
#$memTotalinmb = 16384    # 32GB = 32768; 16GB = 16384; 12GB = 12288
#$memTotalinmb = 16384    # 32GB = 32768; 16GB = 16384; 12GB = 12288

# Golden Image - Only Un-remark one of these
$GoldenVmName  = "W11-1" # Golden Image 1
#$GoldenVmName  = "W11-2" # Golden Image 2



# Golden Image Snapshot - Only Un-remark one of these
$SnapshotName  = "20260402_1" # LAB POOL

# Push Image Options
$LogoffPolicy = "WAIT_FOR_LOGOFF"   # WAIT_FOR_LOGOFF or FORCE_LOGOFF
$StopOnError  = $true

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

        Write-Host "Horizon Token expires at: $expirationTime"
        return $expirationTime
    }
    catch {
        Write-Host "Horizon Token is invalid or unreadable — skipping expiration check." -ForegroundColor Yellow
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

Function Get-HorizonVersion {

$apiDocsUri = "$connectionServer/rest/v1/api-docs/Default"

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
    default { $dpVer = "unknown" }
}

Function Get-vCenterSession {

#Import-Module VMware.PowerCLI
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
$vCenterCreds = Get-Credential -Message "Enter vCenter Admin Credentials (username or username@domain)"
Write-Host "Connecting to vCenter..."
Connect-VIServer -Server $vCenterServer -Credential $vCenterCreds | Out-Null
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -confirm:$false

}

# ==============================
# Check for valid vCenter session
# ==============================

if ($global:DefaultVIServers.Name -contains $vCenterServer) {
    Write-Host "Already connected to $vCenterServer" -ForegroundColor Green
} else {
    Write-Host "Connecting to $vCenterServer" -ForegroundColor Red
    Get-vCenterSession
}



# ==============================
# GET VM & SNAPSHOT (vCenter)
# ==============================

Write-Host "Retrieving golden image VM..."
$vm = Get-VM -Name $GoldenVmName -ErrorAction Stop

Write-Host "Retrieving snapshot..."
$snapshot = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction Stop

# Convert PowerCLI IDs to Horizon IDs
$ParentVmId = $vm.Id -replace "^VirtualMachine-", ""
$SnapshotId = $snapshot.Id -replace "^VirtualMachineSnapshot-", ""

Write-Host "Parent VM ID : $ParentVmId"
Write-Host "Snapshot ID  : $SnapshotId"

# ==============================
# GET DESKTOP POOL ID
# ==============================

Write-Host "Locating desktop pool..."

#
$pools = Invoke-RestMethod -Method Get -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} -SkipCertificateCheck
#

$pool = $pools | Where-Object { $_.name -eq $DesktopPoolName }

if (-not $pool) {
    throw "Desktop pool '$DesktopPoolName' not found"
}

$PoolId = $pool.id
Write-Host "Desktop Pool ID: $PoolId"


Write-Host "Checking for active sessions in pool..."

$sessionsUri = "$connectionServer/rest/inventory/v7/sessions"

$sessions = Invoke-RestMethod -Method Get -Uri $sessionsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

# Filter sessions belonging to this pool that are actively logged in
$activeSessions = $sessions | Where-Object {
    $_.desktop_pool_id -eq $PoolId -and
    $_.session_state -notin @("DISCONNECTED", "ENDED")
}

#if ($activeSessions.Count -gt 0) {
#    Write-Host "❌ Active user sessions detected in pool '$DesktopPoolName'." -ForegroundColor Red
#    Write-Host "Push image will NOT be scheduled." -ForegroundColor Red
#
#    $activeSessions | Select-Object user_id, session_state, start_time | Format-Table
#
#    throw "Aborting image push: users are still logged on."
#}

#Write-Host "✅ No active sessions detected. Safe to continue." -ForegroundColor Green



$pushUri = "$connectionServer/rest/inventory/v2/desktop-pools/$PoolId/action/schedule-push-image"

# ==============================
# PUSH IMAGE
# ==============================

Write-Host "Scheduling push image..."

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

$pushBody = @{
    compute_profile_num_cores_per_socket    = $cpuCoresPerSocket
    compute_profile_num_cpus                = $cpusTotal
    compute_profile_ram_mb                  = $memTotalinmb
    parent_vm_id                            = $ParentVmId
    snapshot_id                             = $SnapshotId
    logoff_policy                           = $LogoffPolicy
    start_time                              = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    stop_on_first_error                     = $StopOnError
} | ConvertTo-Json -Depth 5

$response = Invoke-RestMethod -Method Post -Uri $pushUri `
    -Headers $headers `
    -Body $pushBody




Write-Host "✅ Push image successfully scheduled."

# ==============================
# CLEANUP
# ==============================



# Disconnect-VIServer -Server $vCenterServer -confirm:$false


## Issues == Make sure vCenter connection check is working
