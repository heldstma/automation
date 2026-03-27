#################################################
## BROADCAST MESSAGE UTILITY - Omnissa Horizon ##
##      This utility can be used to send a     ##
##      broadcast message to all sessions      ##
##          Uses the Horizon REST api          ##
##    Created by Matt Heldstab -- 11/21/2025   ##
##          Current version -- 1.1  3/26/2026  ##
## 1.1 - Forces SessionIDs into an array just  ##
##       in case there is only one session     ##
#################################################

$connectionServer = "https://YOUR-CONNECTION-SERVER-FQDN"
$domain = "YOUR-AD-DOMAIN.local"

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



Write-Host "Building session list"

# Endpoint to list sessions
$sessionsUri = "$ConnectionServer/rest/inventory/v7/sessions"

# Call the API
$sessionsResponse = Invoke-RestMethod -Method GET -Uri $sessionsUri -Headers @{
    "Authorization" = "Bearer $Token"
    "Accept"        = "application/json"
} # -SkipCertificateCheck


$sessionsArray = @($sessionsResponse)

# Output to verify
$sessionsArray | ForEach-Object {
    [pscustomobject]@{
        SessionId      = $_.id
        UserId         = $_.user_id
        State          = $_.session_state
        StartTime      = $_.start_time
        SessionType    = $_.session_type
    }
}
$sessionIds = $sessionsArray.id   # Extract all IDs into an array
$sessionCount = $sessionsArray.count
$MessageToSend = read-host "Type the message you would like to send to all users"
$MessageType = read-host "What is the message type (ERROR, WARNING, INFO)"

$messagePayload = @{
    message_type = $MessageType
    message = $MessageToSend
    session_ids = @($sessionIds) # Forces the session IDs into an array format even if there is only one session 
} | ConvertTo-Json

Write-Host "Preparing to send this message to $sessionCount users"  -ForegroundColor Yellow
Write-Host "Message Type: $MessageType"  -ForegroundColor Green
Write-Host $MessageToSend  -ForegroundColor Green

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


$messageUri = "$ConnectionServer/rest/inventory/v1/sessions/action/send-message"

Invoke-RestMethod -Method POST -Uri $messageUri -Headers @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
} -Body $messagePayload # -SkipCertificateCheck

