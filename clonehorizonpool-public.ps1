#################################################
##          HORIZON POOL CLONE UTILITY         ##
##      This utility can be used to clone a    ##
##      current VDI Pool to another one        ##
##          Uses the Horizon REST api          ##
##    Created by Matt Heldstab -- 7 Jan 2026   ##
##          Current version -- 1.1             ##
## Uses the v12 inventory endpoint Build 2512  ##
## For your endpoints, browse the Swagger UI   ##
##    HZN/rest/swagger-ui/index.html for info  ##
#################################################

# Customizeable Variables
$poolNameToClone = "WIN11A" # "SourcePool1" for example
$poolNameToCreate = "WIN11B" # "NewPool1" for example
$poolNamingConventionToCreate = "WIN11B{n:fixed=2}" # "POOL1-{n:fixed=2}" for example
$PoolDisplayNameToCreate = "Windows 11 Pool B"
# If you remark the above line, you must also remark a line further down in the script - search for $newPool.display_name


# Test to see if a valid token exists
$tokenvaliditytest = @()
$tokenvaliditytest = Invoke-RestMethod -Method Get -Uri $connectionServer/rest/monitor/connection-servers -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck

Write-Host "Testing for valid token" -ForegroundColor Yellow

if ($tokenValidityTest.status -ne "OK") {

    Write-Host "Token invalid - Re-authenticating" -ForegroundColor Yellow

    $creds = Get-Credential -Message "Enter Horizon admin credentials"
    # Define Connection Server
    $connectionServer = "https://connection-server-fqdn-here"
    $domain = "AD domain FQDN here"     # Your AD domain
    # Extract real username + password
    $username = $creds.UserName
    $password = $creds.GetNetworkCredential().Password

# If user typed DOMAIN\username, split it
    if ($username -match "\\") {
    $domain, $username = $username -split "\\", 2
    }

# Step 1: Authenticate with JSON body including domain
    $authUri = "$connectionServer/rest/login"   # If this works for you, keep it.
    $body = @{
    username = $username
    password = $password
    domain   = $domain
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Method Post -Uri $authUri `
    -Body $body `
    -ContentType "application/json" `
    # -SkipCertificateCheck

    # Extract token
    $token = $response.access_token
    # Example:
    # Restart-Service WinRM

    # Placeholder command:

}


# Extract real username + password
$username = $creds.UserName
$password = $creds.GetNetworkCredential().Password

# If user typed DOMAIN\username, split it
if ($username -match "\\") {
    $domain, $username = $username -split "\\", 2
}

# Step 1: Authenticate with JSON body including domain
$authUri = "$connectionServer/rest/login"   # If this works for you, keep it.
$body = @{
    username = $username
    password = $password
    domain   = $domain
} | ConvertTo-Json

$response = Invoke-RestMethod -Method Post -Uri $authUri `
    -Body $body `
    -ContentType "application/json" `
#    -SkipCertificateCheck

# Extract token
$token = $response.access_token

# Get all pools
$poolsUri = "$connectionServer/rest/inventory/v12/desktop-pools"
$pools = Invoke-RestMethod -Method GET -Uri $poolsUri -Headers @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck

# Find the pool to clone
$pool = $pools | Where-Object { $_.name -eq $poolNameToClone }
$poolId = $pool.id

# Get full pool object
$poolUri = "$connectionServer/rest/inventory/v12/desktop-pools/$poolId"
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


# Unremark line below to change pool display name
$newPool.display_name = $poolDisplayNameToCreate

$newPool.pattern_naming_settings.naming_pattern = $poolNamingConventionToCreate

$newPoolBody = $newPool | ConvertTo-Json -Depth 20

write-host "You are about to create a pool called:" $newpool.name
write-host "Pool Description:" $newpool.display_name
write-host "Minimum number of Virtual Machines will be:" $newpool.pattern_naming_settings.min_number_of_machines
write-host "VM Naming Pattern:" $newpool.pattern_naming_settings.naming_pattern

do {
    $answer = Read-Host "Type YES to continue or NO to stop"

    $upperAnswer = $answer.ToUpper()

    if ($upperAnswer -eq "YES") {
        Write-Host "Continuing script..."
        $validInput = $true
    }
    elseif ($upperAnswer -eq "NO") {
        Write-Host "Stopping script..."
        exit  # completely stop script execution
    }
    else {
        Write-Host "Invalid input. Please type YES or NO." -ForegroundColor Yellow
        $validInput = $false
    }
} while (-not $validInput)


# Create the new pool
$newPoolUri = "$connectionServer/rest/inventory/v12/desktop-pools"
$newPoolResult = Invoke-RestMethod -Method POST -Uri $newPoolUri -Headers @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
} -Body $newPoolBody # -SkipCertificateCheck

$newPoolResult

