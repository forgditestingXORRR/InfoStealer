#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$ServiceName = 'TimeChanger'
$SysPath     = Join-Path $PSScriptRoot 'TimeChanger.sys'

# --- 1. Sanity checks -------------------------------------------------------
if (-not (Test-Path $SysPath)) {
    throw "Driver file not found: $SysPath"
}
$SysPath = (Resolve-Path $SysPath).Path   # absolute path, required by SCM

# --- 2. Test-signing must be on (requires reboot if just enabled) ----------
$ts = (bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes')
if (-not $ts) {
    Write-Warning "Test signing is OFF. Enabling it now — you MUST reboot before the driver will load."
    bcdedit /set testsigning on | Out-Null
}

# --- 3. Remove any stale service -------------------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing service..."
    if ($existing.Status -eq 'Running') { Stop-Service $ServiceName -Force }
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Milliseconds 500
}

# --- 4. Create the service with an ABSOLUTE path ---------------------------
#   NOTE: sc.exe requires the literal form  binPath= "C:\path\file.sys"
#   (space after '=', quotes around the path). Do NOT use PowerShell's
#   native New-Service for kernel drivers — it mangles the type.
Write-Host "Creating service -> $SysPath"
$out = sc.exe create $ServiceName type= kernel start= demand binPath= "`"$SysPath`"" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "sc create failed ($LASTEXITCODE):`n$out"
}

# --- 5. Verify SCM actually recorded the path ------------------------------
$qc = sc.exe qc $ServiceName
$binLine = $qc | Select-String 'BINARY_PATH_NAME'
Write-Host $binLine
if ($binLine -notmatch [regex]::Escape($SysPath)) {
    throw "SCM did not record the expected path. Got: $binLine"
}

# --- 6. Start the driver ----------------------------------------------------
Write-Host "Starting driver..."
sc.exe start $ServiceName
if ($LASTEXITCODE -ne 0) {
    Write-Host "--- System log (last 10 driver-related errors) ---"
    Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2,3} -MaxEvents 10 |
        Where-Object { $_.ProviderName -match 'Service Control Manager|Kernel' } |
        Format-Table TimeCreated, ProviderName, Id, Message -AutoSize
    throw "sc start failed ($LASTEXITCODE). See errors above."
}

# --- 7. Confirm the device object now exists -------------------------------
Start-Sleep -Milliseconds 300
$dev = Get-Service $ServiceName
if ($dev.Status -ne 'Running') {
    throw "Service not RUNNING (status = $($dev.Status))."
}

# Try to open the symbolic link the same way the GUI does
$h = [System.IO.File]::Open('\\.\TimeChanger', 'Open', 'ReadWrite', 'None')
$h.Close()
Write-Host "OK: \\.\TimeChanger is openable. Driver is live." -ForegroundColor Green