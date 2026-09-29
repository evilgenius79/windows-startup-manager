#Requires -Version 5.1
<#
.SYNOPSIS
    Wrap StartupManager.ps1 into a Windows GUI executable with PS2EXE.

.DESCRIPTION
    Installs the ps2exe module if needed, then builds dist\StartupManager.exe.
    The exe still uses Windows PowerShell under the hood. It is a wrapper,
    not a separately compiled .NET app.

    Run this script from the repo folder:
        powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoAdminManifest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
if (-not $root) { $root = Get-Location }
$inputFile  = Join-Path $root 'StartupManager.ps1'
$outDir     = Join-Path $root 'dist'
$outputFile = Join-Path $outDir 'StartupManager.exe'
$iconFile   = Join-Path $root 'StartupManager.ico'

if (-not (Test-Path -LiteralPath $inputFile)) {
    throw "StartupManager.ps1 not found next to this script: $root"
}

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing ps2exe from PSGallery...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -eq 'Trusted') {
        try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted } catch { }
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -Force
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$invoke = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
if (-not $invoke) {
    throw 'ps2exe installed but Invoke-ps2exe was not found.'
}

$params = @{
    inputFile    = $inputFile
    outputFile   = $outputFile
    noConsole    = $true
    sta          = $true
    title        = 'Windows Startup Manager'
    description  = 'List and disable Windows startup items, firewall, and Defender real-time protection'
    company      = 'windows-startup-manager'
    product      = 'Windows Startup Manager'
    copyright    = 'MIT'
    version      = '1.0.0'
    noError      = $true
    requireAdmin = (-not $NoAdminManifest)
}

if (Test-Path -LiteralPath $iconFile) {
    $params.iconFile = $iconFile
    Write-Host "Using icon $iconFile"
}

Write-Host "Building $outputFile"
Invoke-ps2exe @params

if (-not (Test-Path -LiteralPath $outputFile)) {
    throw 'Build finished but the exe was not created.'
}

Get-Item $outputFile | Select-Object FullName, Length, LastWriteTime | Format-List
Write-Host @"
Done.

The exe will trigger a UAC prompt because it requests Administrator.
SmartScreen may warn on first run because the file is unsigned.
If Windows Defender quarantines it, that is a known false-positive pattern
for PS2EXE wrappers. Unblock the file if needed:

    Unblock-File "$outputFile"
"@
