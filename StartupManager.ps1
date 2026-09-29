#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Startup Manager - GUI inventory of items that run at boot or logon,
    with enable/disable support.

.DESCRIPTION
    Lists startup entries from:
      - Registry Run / RunOnce (HKCU, HKLM, Wow6432Node)
      - Current-user and All-users Startup folders
      - Scheduled tasks with At startup / At logon triggers
      - Services set to Automatic or Automatic (Delayed Start)

    Disable is reversible where possible:
      - Registry / folder items: StartupApproved (same method Task Manager uses)
      - Startup folder shortcuts: rename to *.disabled
      - Scheduled tasks: Disable-ScheduledTask / Enable-ScheduledTask
      - Services: change StartupType (Disabled <-> Automatic)

    Also includes a Firewall & antivirus panel:
      - Windows Firewall per-profile and master on/off
      - Microsoft Defender real-time protection (until reboot)
      - Persistent Defender real-time policy (survives reboot only if
        Tamper Protection is turned off in Windows Security first)

.NOTES
    Run as Administrator to change machine-wide (HKLM) items, services,
    firewall, and Defender. A "Relaunch as Admin" button is provided.

    This is not a full replacement for Sysinternals Autoruns. It covers the
    locations that most often affect boot/logon time.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# STA + WinForms
# -----------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    $psi.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($psi)
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ApprovedByte {
    param([ValidateSet('Enabled','Disabled')][string]$State)
    if ($State -eq 'Enabled') {
        return [byte[]](0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
    }
    return [byte[]](0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
}

function Test-ApprovedEnabled {
    param([byte[]]$Value)
    if (-not $Value -or $Value.Length -lt 1) { return $true }
    # 0x02 = enabled (Task Manager / Settings). Anything else is treated as disabled.
    return ($Value[0] -eq 0x02)
}

function Get-ApprovedState {
    param(
        [string]$ApprovedPath,
        [string]$Name
    )
    if (-not $ApprovedPath -or -not (Test-Path -LiteralPath $ApprovedPath)) {
        return 'Enabled'
    }
    try {
        $item = Get-ItemProperty -LiteralPath $ApprovedPath -ErrorAction Stop
        $prop = $item.PSObject.Properties | Where-Object { $_.Name -eq $Name }
        if (-not $prop) { return 'Enabled' }
        if (Test-ApprovedEnabled -Value ([byte[]]$prop.Value)) { return 'Enabled' }
        return 'Disabled'
    }
    catch {
        return 'Enabled'
    }
}

function Set-ApprovedState {
    param(
        [string]$ApprovedPath,
        [string]$Name,
        [ValidateSet('Enabled','Disabled')][string]$State
    )
    if (-not $ApprovedPath) { throw "No StartupApproved path for this item." }
    if (-not (Test-Path -LiteralPath $ApprovedPath)) {
        New-Item -Path $ApprovedPath -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $ApprovedPath -Name $Name -PropertyType Binary `
        -Value (Get-ApprovedByte $State) -Force | Out-Null
}

function New-StartupItem {
    param(
        [string]$Name,
        [string]$Type,
        [string]$Scope,
        [string]$State,
        [string]$Command,
        [string]$Location,
        [string]$Publisher,
        [hashtable]$Meta
    )
    [pscustomobject]@{
        Name      = $Name
        Type      = $Type
        Scope     = $Scope
        State     = $State
        Command   = $Command
        Location  = $Location
        Publisher = $Publisher
        Meta      = $Meta
    }
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-FilePublisher {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $exe = $null
    if ($CommandLine -match '^\s*"([^"]+)"') {
        $exe = $Matches[1]
    }
    else {
        $exe = ($CommandLine -split '\s+')[0]
    }
    $exe = [Environment]::ExpandEnvironmentVariables($exe)
    if (-not (Test-Path -LiteralPath $exe)) { return '' }
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
        if ($vi.CompanyName) { return $vi.CompanyName }
        return ''
    }
    catch { return '' }
}

function Get-ShortcutTarget {
    param([string]$Path)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($Path)
        $target = $lnk.TargetPath
        $args = $lnk.Arguments
        if ($args) { return "$target $args" }
        return $target
    }
    catch {
        return $Path
    }
}

# -----------------------------------------------------------------------------
# Collectors
# -----------------------------------------------------------------------------
function Get-RegistryRunItems {
    $defs = @(
        @{
            Path     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            Scope    = 'Current user'
            Type     = 'Registry (Run)'
            Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        @{
            Path     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            Scope    = 'Current user'
            Type     = 'Registry (RunOnce)'
            Approved = $null
        }
        @{
            Path     = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
            Scope    = 'All users'
            Type     = 'Registry (Run)'
            Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        @{
            Path     = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            Scope    = 'All users'
            Type     = 'Registry (RunOnce)'
            Approved = $null
        }
        @{
            Path     = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
            Scope    = 'All users (32-bit)'
            Type     = 'Registry (Run 32-bit)'
            Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        }
        @{
            Path     = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
            Scope    = 'All users (32-bit)'
            Type     = 'Registry (RunOnce 32-bit)'
            Approved = $null
        }
        @{
            Path     = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
            Scope    = 'Current user (32-bit)'
            Type     = 'Registry (Run 32-bit)'
            Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        }
    )

    $skip = @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')
    foreach ($d in $defs) {
        if (-not (Test-Path -LiteralPath $d.Path)) { continue }
        try { $props = Get-ItemProperty -LiteralPath $d.Path } catch { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($skip -contains $p.Name) { continue }
            $cmd = [string]$p.Value
            $state = if ($d.Approved) { Get-ApprovedState -ApprovedPath $d.Approved -Name $p.Name } else { 'Enabled' }
            New-StartupItem -Name $p.Name -Type $d.Type -Scope $d.Scope -State $state `
                -Command $cmd -Location $d.Path -Publisher (Get-FilePublisher $cmd) `
                -Meta @{
                    Kind         = 'Registry'
                    ValueName    = $p.Name
                    RegPath      = $d.Path
                    ApprovedPath = $d.Approved
                    IsRunOnce    = ($d.Type -like '*RunOnce*')
                }
        }
    }
}

function Get-FolderStartupItems {
    $defs = @(
        @{
            Path     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
            Scope    = 'Current user'
            Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        }
        @{
            Path     = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
            Scope    = 'All users'
            Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        }
    )

    foreach ($d in $defs) {
        if (-not (Test-Path -LiteralPath $d.Path)) { continue }
        Get-ChildItem -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object {
                $disabledByName = $_.Name -like '*.disabled'
                $displayName = if ($disabledByName) { $_.Name -replace '\.disabled$','' } else { $_.Name }
                $cmd = if ($_.Extension -eq '.lnk') { Get-ShortcutTarget $_.FullName } else { $_.FullName }
                $approvedName = $displayName
                $approvedState = Get-ApprovedState -ApprovedPath $d.Approved -Name $approvedName
                $state = if ($disabledByName) { 'Disabled' } else { $approvedState }
                New-StartupItem -Name $displayName -Type 'Startup folder' -Scope $d.Scope -State $state `
                    -Command $cmd -Location $_.FullName -Publisher (Get-FilePublisher $cmd) `
                    -Meta @{
                        Kind         = 'Folder'
                        FilePath     = $_.FullName
                        ApprovedPath = $d.Approved
                        ApprovedName = $approvedName
                    }
            }
    }
}

function Test-TaskIsStartupOrLogon {
    param($Task)
    if (-not $Task.Triggers) { return $false }
    foreach ($t in @($Task.Triggers)) {
        $cls = ''
        try { $cls = $t.CimClass.CimClassName } catch { $cls = $t.GetType().Name }
        if ($cls -match 'LogonTrigger|BootTrigger') { return $true }
        try {
            if ($t.CimInstanceProperties['Delay'] -and $t.PSObject.Properties.Name -contains 'UserId') { return $true }
        } catch {}
    }
    return $false
}

function Get-TaskTriggerLabel {
    param($Task)
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($t in @($Task.Triggers)) {
        $cls = ''
        try { $cls = $t.CimClass.CimClassName } catch { $cls = '' }
        if ($cls -match 'BootTrigger')   { [void]$labels.Add('At startup') }
        elseif ($cls -match 'LogonTrigger') { [void]$labels.Add('At logon') }
    }
    if ($labels.Count -eq 0) { return 'Startup/logon' }
    return (($labels | Select-Object -Unique) -join ', ')
}

function Get-ScheduledStartupItems {
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop
    }
    catch {
        return
    }

    foreach ($task in $tasks) {
        try {
        if (-not (Test-TaskIsStartupOrLogon $task)) { continue }

        $actionLines = New-Object System.Collections.Generic.List[string]
        foreach ($act in @($task.Actions)) {
            if ($null -eq $act) { continue }
            $e = [string](Get-Prop $act 'Execute' '')
            $a = [string](Get-Prop $act 'Arguments' '')
            $c = [string](Get-Prop $act 'ClassId' '')
            $d = [string](Get-Prop $act 'Data' '')
            if ($e) {
                if ($a) { [void]$actionLines.Add("$e $a") } else { [void]$actionLines.Add($e) }
            }
            elseif ($c) {
                [void]$actionLines.Add("COM: $c")
            }
            elseif ($d) {
                [void]$actionLines.Add($d)
            }
            else {
                $cls = ''
                try { $cls = $act.CimClass.CimClassName } catch { $cls = $act.GetType().Name }
                [void]$actionLines.Add($cls)
            }
        }
        $cmd = ($actionLines -join ' | ')
        $stateName = [string](Get-Prop $task 'State' '')
        $state = if ($stateName -eq 'Disabled') { 'Disabled' } else { 'Enabled' }
        $taskPath = [string](Get-Prop $task 'TaskPath' '\')
        $taskName = [string](Get-Prop $task 'TaskName' '')
        $fullName = ($taskPath.TrimEnd('\') + '\' + $taskName)
        $author = [string](Get-Prop $task 'Author' '')
        New-StartupItem -Name $taskName -Type 'Scheduled task' -Scope (Get-TaskTriggerLabel $task) `
            -State $state -Command $cmd -Location $fullName `
            -Publisher $(if ($taskPath -like '\Microsoft\*') { 'Microsoft' } else { Get-FilePublisher $cmd }) `
            -Meta @{
                Kind     = 'Task'
                TaskName = $taskName
                TaskPath = $taskPath
                Author   = $author
            }
        }
        catch {
            # Skip a single unreadable task instead of aborting the whole scan.
            continue
        }
    }
}

function Get-AutomaticServices {
    try {
        $svcs = Get-CimInstance Win32_Service -ErrorAction Stop |
            Where-Object { $_.StartMode -in @('Auto','Automatic') -or $_.DelayedAutoStart }
    }
    catch {
        Get-Service | Where-Object { $_.StartType -in @('Automatic','AutomaticDelayedStart') } | ForEach-Object {
            New-StartupItem -Name $_.Name -Type 'Service' -Scope $_.StartType -State $(if ($_.StartType -eq 'Disabled') {'Disabled'} else {'Enabled'}) `
                -Command '' -Location $_.Name -Publisher '' -Meta @{ Kind = 'Service'; ServiceName = $_.Name; DisplayName = $_.DisplayName }
        }
        return
    }

    foreach ($s in $svcs) {
        $delayed = [bool](Get-Prop $s 'DelayedAutoStart' $false)
        $startMode = [string](Get-Prop $s 'StartMode' '')
        $pathName = [string](Get-Prop $s 'PathName' '')
        $display = [string](Get-Prop $s 'DisplayName' '')
        $svcName = [string](Get-Prop $s 'Name' '')
        $startLabel = if ($delayed) { 'Automatic (Delayed)' } else { 'Automatic' }
        $state = if ($startMode -eq 'Disabled') { 'Disabled' } else { 'Enabled' }
        $pub = Get-FilePublisher $pathName
        if (-not $pub -and $pathName -match '\\Windows\\System32\\') { $pub = 'Microsoft Corporation' }
        New-StartupItem -Name $display -Type 'Service' -Scope $startLabel -State $state `
            -Command $pathName -Location $svcName -Publisher $pub `
            -Meta @{
                Kind         = 'Service'
                ServiceName  = $svcName
                DisplayName  = $display
                Delayed      = $delayed
                OriginalMode = $startMode
            }
    }
}

function Get-AllStartupItems {
    $list = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $collectors = @(
        @{ Name = 'registry';  Fn = { Get-RegistryRunItems } },
        @{ Name = 'folder';    Fn = { Get-FolderStartupItems } },
        @{ Name = 'task';      Fn = { Get-ScheduledStartupItems } },
        @{ Name = 'service';   Fn = { Get-AutomaticServices } }
    )
    foreach ($c in $collectors) {
        try {
            foreach ($i in @(& $c.Fn)) {
                if ($i) { $list.Add($i) }
            }
        }
        catch {
            [void]$warnings.Add("$($c.Name): $($_.Exception.Message)")
        }
    }
    $script:ScanWarnings = $warnings
    return $list
}

# -----------------------------------------------------------------------------
# Enable / Disable
# -----------------------------------------------------------------------------
$script:ProtectedServices = @(
    'DcomLaunch','RpcSs','RpcEptMapper','LSM','EventLog','PlugPlay','Power',
    'SamSs','LanmanServer','LanmanWorkstation','Winmgmt','ProfSvc','UserManager',
    'Schedule','BrokerInfrastructure','SystemEventsBroker','StateRepository',
    'CryptSvc','BFE','mpssvc','WinDefend','WdNisSvc','Sense','SecurityHealthService',
    'Dhcp','Dnscache','NlaSvc','nsi','Netman','Audiosrv','AudioEndpointBuilder',
    'Spooler','Themes','FontCache','WSearch','wuauserv','UsoSvc','bits',
    'WinHttpAutoProxySvc','iphlpsvc','Wcmsvc','WlanSvc','TokenBroker'
)

function Confirm-RiskyChange {
    param($Item, [string]$Action)
    $reasons = @()
    if ($Item.Type -eq 'Service') {
        $svcName = $Item.Meta.ServiceName
        if ($script:ProtectedServices -contains $svcName) {
            $reasons += "This looks like a core Windows service ($svcName)."
        }
        if ($Item.Publisher -match 'Microsoft') {
            $reasons += "Publisher is Microsoft. Disabling it can break Windows features."
        }
    }
    if ($Item.Type -eq 'Scheduled task' -and $Item.Location -like '\Microsoft\*') {
        $reasons += "This is a Microsoft scheduled task."
    }
    if ($reasons.Count -eq 0) { return $true }

    $msg = "You are about to $Action :`n`n$($Item.Name)`n$($Item.Type) - $($Item.Location)`n`n" +
           ($reasons -join "`n") +
           "`n`nContinue anyway?"
    $r = [Windows.Forms.MessageBox]::Show($msg, "Confirm $Action", 'YesNo', 'Warning')
    return ($r -eq 'Yes')
}

function Disable-StartupItem {
    param($Item)
    switch ($Item.Meta.Kind) {
        'Registry' {
            if ($Item.Meta.IsRunOnce) {
                Remove-ItemProperty -LiteralPath $Item.Meta.RegPath -Name $Item.Meta.ValueName -Force
            }
            elseif ($Item.Meta.ApprovedPath) {
                Set-ApprovedState -ApprovedPath $Item.Meta.ApprovedPath -Name $Item.Meta.ValueName -State Disabled
            }
            else {
                Remove-ItemProperty -LiteralPath $Item.Meta.RegPath -Name $Item.Meta.ValueName -Force
            }
        }
        'Folder' {
            $path = $Item.Meta.FilePath
            if ($path -and (Test-Path -LiteralPath $path) -and $path -notlike '*.disabled') {
                Rename-Item -LiteralPath $path -NewName (($path | Split-Path -Leaf) + '.disabled')
            }
            if ($Item.Meta.ApprovedPath) {
                Set-ApprovedState -ApprovedPath $Item.Meta.ApprovedPath -Name $Item.Meta.ApprovedName -State Disabled
            }
        }
        'Task' {
            Disable-ScheduledTask -TaskName $Item.Meta.TaskName -TaskPath $Item.Meta.TaskPath | Out-Null
        }
        'Service' {
            Set-Service -Name $Item.Meta.ServiceName -StartupType Disabled
        }
        default { throw "Unknown item kind: $($Item.Meta.Kind)" }
    }
}

function Enable-StartupItem {
    param($Item)
    switch ($Item.Meta.Kind) {
        'Registry' {
            if ($Item.Meta.IsRunOnce) {
                throw "RunOnce entries are one-shot. Once removed they cannot be re-enabled from this tool."
            }
            if (-not $Item.Meta.ApprovedPath) {
                throw "No StartupApproved key available to re-enable this registry value."
            }
            Set-ApprovedState -ApprovedPath $Item.Meta.ApprovedPath -Name $Item.Meta.ValueName -State Enabled
        }
        'Folder' {
            $path = $Item.Meta.FilePath
            if ($path -like '*.disabled' -and (Test-Path -LiteralPath $path)) {
                $orig = $path -replace '\.disabled$',''
                Rename-Item -LiteralPath $path -NewName (Split-Path $orig -Leaf)
                $Item.Meta.FilePath = $orig
            }
            if ($Item.Meta.ApprovedPath) {
                Set-ApprovedState -ApprovedPath $Item.Meta.ApprovedPath -Name $Item.Meta.ApprovedName -State Enabled
            }
        }
        'Task' {
            Enable-ScheduledTask -TaskName $Item.Meta.TaskName -TaskPath $Item.Meta.TaskPath | Out-Null
        }
        'Service' {
            $mode = if ($Item.Meta.Delayed) { 'Automatic' } else { 'Automatic' }
            Set-Service -Name $Item.Meta.ServiceName -StartupType Automatic
        }
        default { throw "Unknown item kind: $($Item.Meta.Kind)" }
    }
}

# -----------------------------------------------------------------------------
# Firewall & Microsoft Defender
# -----------------------------------------------------------------------------
$script:DefenderPolicyRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$script:DefenderRtpPolicy  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'

function Test-DefenderCmdletsAvailable {
    return $null -ne (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)
}

function Get-InstalledAntivirusProducts {
    $list = New-Object System.Collections.Generic.List[string]
    try {
        $products = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop
        foreach ($p in @($products)) {
            if ($p.displayName) { [void]$list.Add([string]$p.displayName) }
        }
    }
    catch { }
    if ($list.Count -eq 0) { [void]$list.Add('Unknown / Security Center unavailable') }
    return $list
}

function Test-PersistentRtpPolicyDisabled {
    if (-not (Test-Path -LiteralPath $script:DefenderRtpPolicy)) { return $false }
    try {
        $v = Get-ItemProperty -LiteralPath $script:DefenderRtpPolicy -ErrorAction Stop
        return ([int]$v.DisableRealtimeMonitoring -eq 1)
    }
    catch {
        return $false
    }
}

function Get-SecurityStatus {
    $status = [ordered]@{
        FirewallDomain   = $null
        FirewallPrivate  = $null
        FirewallPublic   = $null
        FirewallAnyOn    = $false
        DefenderPresent  = $false
        DefenderEnabled  = $null
        RealTimeOn       = $null
        TamperProtected  = $null
        PersistentPolicy = Test-PersistentRtpPolicyDisabled
        AvProducts       = (Get-InstalledAntivirusProducts)
        Error            = $null
    }

    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            $on = ($p.Enabled -eq $true -or [string]$p.Enabled -eq 'True' -or [string]$p.Enabled -eq 'On')
            switch ([string]$p.Name) {
                'Domain'  { $status.FirewallDomain  = $on }
                'Private' { $status.FirewallPrivate = $on }
                'Public'  { $status.FirewallPublic  = $on }
            }
        }
        $status.FirewallAnyOn = ($status.FirewallDomain -or $status.FirewallPrivate -or $status.FirewallPublic)
    }
    catch {
        $status.Error = "Firewall: $($_.Exception.Message)"
    }

    if (Test-DefenderCmdletsAvailable) {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $status.DefenderPresent = $true
            $status.DefenderEnabled = [bool]$mp.AntivirusEnabled
            $status.RealTimeOn      = [bool]$mp.RealTimeProtectionEnabled
            $status.TamperProtected = [bool]$mp.IsTamperProtected
        }
        catch {
            $status.DefenderPresent = $true
            $status.Error = (($status.Error, "Defender: $($_.Exception.Message)") | Where-Object { $_ }) -join ' | '
        }
    }

    return [pscustomobject]$status
}

function Set-FirewallMaster {
    param([bool]$Enabled)
    if (-not $script:IsAdmin) { throw 'Administrator rights are required to change Windows Firewall.' }
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled $Enabled -ErrorAction Stop
}

function Set-FirewallProfileState {
    param(
        [ValidateSet('Domain','Private','Public')][string]$Profile,
        [bool]$Enabled
    )
    if (-not $script:IsAdmin) { throw 'Administrator rights are required to change Windows Firewall.' }
    Set-NetFirewallProfile -Profile $Profile -Enabled $Enabled -ErrorAction Stop
}

function Set-DefenderRealtimeTemporary {
    param([bool]$Enabled)
    if (-not $script:IsAdmin) { throw 'Administrator rights are required to change Microsoft Defender.' }
    if (-not (Test-DefenderCmdletsAvailable)) { throw 'Microsoft Defender PowerShell cmdlets are not available on this PC.' }
    # $true for DisableRealtimeMonitoring means RTP is OFF.
    Set-MpPreference -DisableRealtimeMonitoring (-not $Enabled) -ErrorAction Stop
}

function Set-DefenderRealtimePersistent {
    param([bool]$Enabled)
    if (-not $script:IsAdmin) { throw 'Administrator rights are required to write Defender policy.' }

    if ($Enabled) {
        # Remove the policy that forces RTP off so Defender can turn it back on.
        if (Test-Path -LiteralPath $script:DefenderRtpPolicy) {
            foreach ($name in @(
                'DisableRealtimeMonitoring',
                'DisableBehaviorMonitoring',
                'DisableIOAVProtection',
                'DisableOnAccessProtection',
                'DisableScanOnRealtimeEnable',
                'DisableIntrusionPreventionSystem'
            )) {
                Remove-ItemProperty -LiteralPath $script:DefenderRtpPolicy -Name $name -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-DefenderCmdletsAvailable) {
            try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue } catch { }
        }
        return
    }

    if (-not (Test-Path -LiteralPath $script:DefenderPolicyRoot)) {
        New-Item -Path $script:DefenderPolicyRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:DefenderRtpPolicy)) {
        New-Item -Path $script:DefenderRtpPolicy -Force | Out-Null
    }

    $names = @(
        'DisableRealtimeMonitoring',
        'DisableBehaviorMonitoring',
        'DisableIOAVProtection',
        'DisableOnAccessProtection',
        'DisableScanOnRealtimeEnable'
    )
    foreach ($name in $names) {
        New-ItemProperty -LiteralPath $script:DefenderRtpPolicy -Name $name -PropertyType DWord -Value 1 -Force | Out-Null
    }

    if (Test-DefenderCmdletsAvailable) {
        try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch { }
    }
}

function Open-WindowsSecurityThreatPage {
    try {
        Start-Process 'windowsdefender://threat/'
    }
    catch {
        Start-Process 'windowsdefender:'
    }
}

# -----------------------------------------------------------------------------
# GUI
# -----------------------------------------------------------------------------
$script:AllItems = @()
$script:IsAdmin  = Test-IsAdmin
$script:SecStatus = $null


$form                 = New-Object Windows.Forms.Form
$form.Text            = 'Windows Startup Manager'
$form.Size            = New-Object Drawing.Size(1280, 840)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object Drawing.Size(1100, 700)
$form.Font            = New-Object Drawing.Font('Segoe UI', 9)

$lblBanner = New-Object Windows.Forms.Label
$lblBanner.Dock = 'Top'
$lblBanner.Height = 36
$lblBanner.TextAlign = 'MiddleLeft'
$lblBanner.Padding = New-Object Windows.Forms.Padding(12, 0, 0, 0)
if ($script:IsAdmin) {
    $lblBanner.Text = '  Running as Administrator - you can change machine-wide items, services, and tasks.'
    $lblBanner.BackColor = [Drawing.Color]::FromArgb(220, 245, 220)
}
else {
    $lblBanner.Text = '  Running as standard user - HKLM, services, and some tasks are read-only. Use "Relaunch as Admin".'
    $lblBanner.BackColor = [Drawing.Color]::FromArgb(255, 243, 205)
}

$top = New-Object Windows.Forms.Panel
$top.Dock = 'Top'
$top.Height = 48
$top.Padding = New-Object Windows.Forms.Padding(8)

$lblFilter = New-Object Windows.Forms.Label
$lblFilter.Text = 'Type:'
$lblFilter.AutoSize = $true
$lblFilter.Location = New-Object Drawing.Point(10, 15)

$cmbType = New-Object Windows.Forms.ComboBox
$cmbType.DropDownStyle = 'DropDownList'
$cmbType.Items.AddRange(@('All','Registry','Startup folder','Scheduled task','Service'))
$cmbType.SelectedIndex = 0
$cmbType.Location = New-Object Drawing.Point(50, 11)
$cmbType.Width = 150

$lblSearch = New-Object Windows.Forms.Label
$lblSearch.Text = 'Search:'
$lblSearch.AutoSize = $true
$lblSearch.Location = New-Object Drawing.Point(220, 15)

$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Location = New-Object Drawing.Point(275, 12)
$txtSearch.Width = 220

$chkHideMsSvc = New-Object Windows.Forms.CheckBox
$chkHideMsSvc.Text = 'Hide Microsoft services'
$chkHideMsSvc.AutoSize = $true
$chkHideMsSvc.Checked = $true
$chkHideMsSvc.Location = New-Object Drawing.Point(510, 6)

$chkHideMsTask = New-Object Windows.Forms.CheckBox
$chkHideMsTask.Text = 'Hide Microsoft tasks'
$chkHideMsTask.AutoSize = $true
$chkHideMsTask.Checked = $true
$chkHideMsTask.Location = New-Object Drawing.Point(510, 26)

$chkEnabledOnly = New-Object Windows.Forms.CheckBox
$chkEnabledOnly.Text = 'Enabled only'
$chkEnabledOnly.AutoSize = $true
$chkEnabledOnly.Location = New-Object Drawing.Point(700, 14)

$lblCount = New-Object Windows.Forms.Label
$lblCount.AutoSize = $true
$lblCount.Location = New-Object Drawing.Point(820, 15)
$lblCount.ForeColor = [Drawing.Color]::DimGray

$top.Controls.AddRange(@($lblFilter,$cmbType,$lblSearch,$txtSearch,$chkHideMsSvc,$chkHideMsTask,$chkEnabledOnly,$lblCount))

$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [Drawing.Color]::White
$grid.BorderStyle = 'None'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(45, 45, 48)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(248, 248, 248)

$cols = @(
    @{ Name = 'Name';      Fill = 18 }
    @{ Name = 'Type';      Fill = 12 }
    @{ Name = 'Scope';     Fill = 12 }
    @{ Name = 'State';     Fill = 8 }
    @{ Name = 'Publisher'; Fill = 14 }
    @{ Name = 'Command';   Fill = 24 }
    @{ Name = 'Location';  Fill = 20 }
)
foreach ($c in $cols) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.Name
    $col.HeaderText = $c.Name
    $col.FillWeight = $c.Fill
    [void]$grid.Columns.Add($col)
}

$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = 'Bottom'
$bottom.Height = 56
$bottom.Padding = New-Object Windows.Forms.Padding(8)

function New-Btn([string]$text, [int]$x, [int]$w = 120) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point($x, 12)
    $b.Size = New-Object Drawing.Size($w, 30)
    $b.FlatStyle = 'System'
    return $b
}

$btnRefresh   = New-Btn 'Refresh' 12
$btnDisable   = New-Btn 'Disable selected' 142 140
$btnEnable    = New-Btn 'Enable selected' 292 140
$btnExport    = New-Btn 'Export CSV' 442
$btnOpen      = New-Btn 'Open location' 572 120
$btnAdmin     = New-Btn 'Relaunch as Admin' 702 150
$btnClose     = New-Btn 'Close' 862 90

if ($script:IsAdmin) { $btnAdmin.Enabled = $false }

$bottom.Controls.AddRange(@($btnRefresh,$btnDisable,$btnEnable,$btnExport,$btnOpen,$btnAdmin,$btnClose))

$sec = New-Object Windows.Forms.GroupBox
$sec.Text = 'Firewall & antivirus'
$sec.Dock = 'Bottom'
$sec.Height = 168

$lblFw = New-Object Windows.Forms.Label
$lblFw.Text = 'Windows Firewall'
$lblFw.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$lblFw.AutoSize = $true
$lblFw.Location = New-Object Drawing.Point(12, 22)

$lblFwState = New-Object Windows.Forms.Label
$lblFwState.AutoSize = $true
$lblFwState.Location = New-Object Drawing.Point(12, 42)
$lblFwState.Text = 'Status: reading...'

$chkFwDomain = New-Object Windows.Forms.CheckBox
$chkFwDomain.Text = 'Domain'
$chkFwDomain.AutoSize = $true
$chkFwDomain.Location = New-Object Drawing.Point(12, 66)

$chkFwPrivate = New-Object Windows.Forms.CheckBox
$chkFwPrivate.Text = 'Private'
$chkFwPrivate.AutoSize = $true
$chkFwPrivate.Location = New-Object Drawing.Point(90, 66)

$chkFwPublic = New-Object Windows.Forms.CheckBox
$chkFwPublic.Text = 'Public'
$chkFwPublic.AutoSize = $true
$chkFwPublic.Location = New-Object Drawing.Point(168, 66)

$btnFwOn = New-Object Windows.Forms.Button
$btnFwOn.Text = 'Firewall ON'
$btnFwOn.Location = New-Object Drawing.Point(12, 96)
$btnFwOn.Size = New-Object Drawing.Size(110, 28)

$btnFwOff = New-Object Windows.Forms.Button
$btnFwOff.Text = 'Firewall OFF'
$btnFwOff.Location = New-Object Drawing.Point(128, 96)
$btnFwOff.Size = New-Object Drawing.Size(110, 28)

$lblAv = New-Object Windows.Forms.Label
$lblAv.Text = 'Microsoft Defender'
$lblAv.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$lblAv.AutoSize = $true
$lblAv.Location = New-Object Drawing.Point(280, 22)

$lblAvState = New-Object Windows.Forms.Label
$lblAvState.Location = New-Object Drawing.Point(280, 42)
$lblAvState.Size = New-Object Drawing.Size(620, 38)
$lblAvState.Text = 'Status: reading...'

$btnRtpOn = New-Object Windows.Forms.Button
$btnRtpOn.Text = 'RTP ON'
$btnRtpOn.Location = New-Object Drawing.Point(280, 84)
$btnRtpOn.Size = New-Object Drawing.Size(90, 28)

$btnRtpOffTemp = New-Object Windows.Forms.Button
$btnRtpOffTemp.Text = 'RTP off until reboot'
$btnRtpOffTemp.Location = New-Object Drawing.Point(376, 84)
$btnRtpOffTemp.Size = New-Object Drawing.Size(150, 28)

$btnRtpOffPersist = New-Object Windows.Forms.Button
$btnRtpOffPersist.Text = 'RTP off after reboot'
$btnRtpOffPersist.Location = New-Object Drawing.Point(532, 84)
$btnRtpOffPersist.Size = New-Object Drawing.Size(150, 28)

$btnRtpClearPolicy = New-Object Windows.Forms.Button
$btnRtpClearPolicy.Text = 'Clear persist policy'
$btnRtpClearPolicy.Location = New-Object Drawing.Point(688, 84)
$btnRtpClearPolicy.Size = New-Object Drawing.Size(140, 28)

$btnOpenSec = New-Object Windows.Forms.Button
$btnOpenSec.Text = 'Open Windows Security'
$btnOpenSec.Location = New-Object Drawing.Point(280, 118)
$btnOpenSec.Size = New-Object Drawing.Size(180, 28)

$btnSecRefresh = New-Object Windows.Forms.Button
$btnSecRefresh.Text = 'Refresh status'
$btnSecRefresh.Location = New-Object Drawing.Point(466, 118)
$btnSecRefresh.Size = New-Object Drawing.Size(120, 28)

$lblAvHint = New-Object Windows.Forms.Label
$lblAvHint.Location = New-Object Drawing.Point(600, 118)
$lblAvHint.Size = New-Object Drawing.Size(640, 36)
$lblAvHint.ForeColor = [Drawing.Color]::DimGray
$lblAvHint.Text = 'If real-time protection turns itself back on after reboot, Tamper Protection is on. Turn that off in Windows Security first, then use "RTP off after reboot".'

$sec.Controls.AddRange(@(
    $lblFw, $lblFwState, $chkFwDomain, $chkFwPrivate, $chkFwPublic, $btnFwOn, $btnFwOff,
    $lblAv, $lblAvState, $btnRtpOn, $btnRtpOffTemp, $btnRtpOffPersist, $btnRtpClearPolicy,
    $btnOpenSec, $btnSecRefresh, $lblAvHint
))

$status = New-Object Windows.Forms.StatusStrip
$statLabel = New-Object Windows.Forms.ToolStripStatusLabel
$statLabel.Spring = $true
$statLabel.Text = 'Ready'
[void]$status.Items.Add($statLabel)

$form.Controls.Add($grid)
$form.Controls.Add($bottom)
$form.Controls.Add($sec)
$form.Controls.Add($top)
$form.Controls.Add($lblBanner)
$form.Controls.Add($status)

# -----------------------------------------------------------------------------
# Binding / filter
# -----------------------------------------------------------------------------
function Test-IsMicrosoftish {
    param($Item)
    if ($Item.Publisher -match 'Microsoft') { return $true }
    if ($Item.Type -eq 'Service' -and ($Item.Command -match '\\Windows\\(System32|SysWOW64)\\' -or $Item.Location -in $script:ProtectedServices)) { return $true }
    if ($Item.Type -eq 'Scheduled task' -and $Item.Location -like '\Microsoft\*') { return $true }
    return $false
}

function Get-FilteredItems {
    $type = $cmbType.SelectedItem
    $q = $txtSearch.Text.Trim()
    $items = $script:AllItems
    if ($type -ne 'All') {
        $items = $items | Where-Object {
            switch ($type) {
                'Registry'        { $_.Type -like 'Registry*' }
                'Startup folder'  { $_.Type -eq 'Startup folder' }
                'Scheduled task'  { $_.Type -eq 'Scheduled task' }
                'Service'         { $_.Type -eq 'Service' }
                default           { $true }
            }
        }
    }
    if ($chkHideMsSvc.Checked) {
        $items = $items | Where-Object { -not ($_.Type -eq 'Service' -and (Test-IsMicrosoftish $_)) }
    }
    if ($chkHideMsTask.Checked) {
        $items = $items | Where-Object { -not ($_.Type -eq 'Scheduled task' -and ($_.Location -like '\Microsoft\*')) }
    }
    if ($chkEnabledOnly.Checked) {
        $items = $items | Where-Object { $_.State -eq 'Enabled' }
    }
    if ($q) {
        $items = $items | Where-Object {
            $_.Name -like "*$q*" -or $_.Command -like "*$q*" -or $_.Location -like "*$q*" -or $_.Publisher -like "*$q*"
        }
    }
    return @($items)
}

function Update-Grid {
    $grid.Rows.Clear()
    $items = Get-FilteredItems
    foreach ($i in $items) {
        $idx = $grid.Rows.Add($i.Name, $i.Type, $i.Scope, $i.State, $i.Publisher, $i.Command, $i.Location)
        $grid.Rows[$idx].Tag = $i
        if ($i.State -eq 'Disabled') {
            $grid.Rows[$idx].DefaultCellStyle.ForeColor = [Drawing.Color]::Gray
        }
        elseif ($i.Type -eq 'Service' -and (Test-IsMicrosoftish $i)) {
            $grid.Rows[$idx].DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(80, 80, 80)
        }
    }
    $lblCount.Text = "$($items.Count) shown  /  $($script:AllItems.Count) total"
    $statLabel.Text = "Loaded $($script:AllItems.Count) startup items."
}

$script:UpdatingSecurityUi = $false

function Update-SecurityPanel {
    $script:UpdatingSecurityUi = $true
    try {
        $script:SecStatus = Get-SecurityStatus
        $s = $script:SecStatus

        $onTxt = { param($v) if ($null -eq $v) { 'n/a' } elseif ($v) { 'ON' } else { 'OFF' } }

        $lblFwState.Text = "Domain: $(& $onTxt $s.FirewallDomain)   Private: $(& $onTxt $s.FirewallPrivate)   Public: $(& $onTxt $s.FirewallPublic)"
        $chkFwDomain.Checked  = [bool]$s.FirewallDomain
        $chkFwPrivate.Checked = [bool]$s.FirewallPrivate
        $chkFwPublic.Checked  = [bool]$s.FirewallPublic

        $avNames = ($s.AvProducts -join ', ')
        $rtp  = if ($null -eq $s.RealTimeOn) { 'n/a' } elseif ($s.RealTimeOn) { 'ON' } else { 'OFF' }
        $tamp = if ($null -eq $s.TamperProtected) { 'n/a' } elseif ($s.TamperProtected) { 'ON (blocks persistent off)' } else { 'OFF' }
        $persist = if ($s.PersistentPolicy) { 'policy set: stay off after reboot' } else { 'no persist policy' }
        $lblAvState.Text = "Realtime: $rtp    Tamper Protection: $tamp    $persist`nDetected AV: $avNames"

        if ($s.TamperProtected) {
            $lblAvState.ForeColor = [Drawing.Color]::FromArgb(140, 80, 0)
        }
        elseif ($s.RealTimeOn -eq $false) {
            $lblAvState.ForeColor = [Drawing.Color]::FromArgb(160, 0, 0)
        }
        else {
            $lblAvState.ForeColor = [Drawing.Color]::FromArgb(0, 90, 0)
        }

        if ($s.Error) { $statLabel.Text = $s.Error }
    }
    catch {
        $lblFwState.Text = 'Could not read firewall / Defender status.'
        $lblAvState.Text = $_.Exception.Message
    }
    finally {
        $script:UpdatingSecurityUi = $false
    }
}

function Refresh-All {
    $statLabel.Text = 'Scanning startup locations...'
    $form.Cursor = 'WaitCursor'
    [Windows.Forms.Application]::DoEvents()
    try {
        $script:ScanWarnings = New-Object System.Collections.Generic.List[string]
        $script:AllItems = @(Get-AllStartupItems | Sort-Object Type, Name)
        Update-Grid
        Update-SecurityPanel
        if ($script:ScanWarnings -and $script:ScanWarnings.Count -gt 0) {
            $statLabel.Text = "Loaded $($script:AllItems.Count) items with $($script:ScanWarnings.Count) warning(s)."
        }
    }
    catch {
        [Windows.Forms.MessageBox]::Show("Failed to scan startup items:`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
        $statLabel.Text = 'Scan failed.'
        try { Update-SecurityPanel } catch { }
    }
    finally {
        $form.Cursor = 'Default'
    }
}

function Get-SelectedItems {
    $list = @()
    foreach ($row in $grid.SelectedRows) {
        if ($row.Tag) { $list += $row.Tag }
    }
    return $list
}

# -----------------------------------------------------------------------------
# Events
# -----------------------------------------------------------------------------
$cmbType.Add_SelectedIndexChanged({ Update-Grid })
$txtSearch.Add_TextChanged({ Update-Grid })
$chkHideMsSvc.Add_CheckedChanged({ Update-Grid })
$chkHideMsTask.Add_CheckedChanged({ Update-Grid })
$chkEnabledOnly.Add_CheckedChanged({ Update-Grid })
$btnRefresh.Add_Click({ Refresh-All })
$btnClose.Add_Click({ $form.Close() })

function Invoke-SecAction {
    param([scriptblock]$Action, [string]$Success)
    try {
        & $Action
        Start-Sleep -Milliseconds 400
        Update-SecurityPanel
        $statLabel.Text = $Success
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Security change failed', 'OK', 'Warning') | Out-Null
        Update-SecurityPanel
    }
}

$btnFwOn.Add_Click({
    Invoke-SecAction { Set-FirewallMaster -Enabled $true } 'Windows Firewall enabled on Domain, Private, and Public.'
})
$btnFwOff.Add_Click({
    $ok = [Windows.Forms.MessageBox]::Show(
        "Turn Windows Firewall OFF on Domain, Private, and Public?`n`nThis exposes the PC on every network until you turn it back on.",
        'Confirm firewall off', 'YesNo', 'Warning')
    if ($ok -ne 'Yes') { return }
    Invoke-SecAction { Set-FirewallMaster -Enabled $false } 'Windows Firewall disabled on all profiles.'
})

function Update-FwFromCheckbox([string]$Profile, $Box) {
    if ($script:UpdatingSecurityUi) { return }
    try {
        Set-FirewallProfileState -Profile $Profile -Enabled $Box.Checked
        Update-SecurityPanel
        $statLabel.Text = "Firewall $Profile set to $(if ($Box.Checked) {'ON'} else {'OFF'})."
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Firewall change failed', 'OK', 'Warning') | Out-Null
        Update-SecurityPanel
    }
}
$chkFwDomain.Add_CheckedChanged({ Update-FwFromCheckbox 'Domain' $chkFwDomain })
$chkFwPrivate.Add_CheckedChanged({ Update-FwFromCheckbox 'Private' $chkFwPrivate })
$chkFwPublic.Add_CheckedChanged({ Update-FwFromCheckbox 'Public' $chkFwPublic })

$btnRtpOn.Add_Click({
    Invoke-SecAction {
        Set-DefenderRealtimePersistent -Enabled $true
        Set-DefenderRealtimeTemporary -Enabled $true
    } 'Defender real-time protection enabled and persist-off policy cleared.'
})

$btnRtpOffTemp.Add_Click({
    $ok = [Windows.Forms.MessageBox]::Show(
        "Turn off Microsoft Defender real-time protection until the next reboot?`n`nWindows often turns it back on after restart, especially if Tamper Protection is on.",
        'Confirm RTP off (until reboot)', 'YesNo', 'Warning')
    if ($ok -ne 'Yes') { return }
    Invoke-SecAction { Set-DefenderRealtimeTemporary -Enabled $false } 'Real-time protection disabled until reboot (or until Defender re-enables it).'
})

$btnRtpOffPersist.Add_Click({
    $s = Get-SecurityStatus
    if ($s.TamperProtected) {
        $go = [Windows.Forms.MessageBox]::Show(
            "Tamper Protection is ON. Windows will usually ignore a persist-off policy and turn real-time protection back on after reboot.`n`nTurn Tamper Protection OFF first:`nWindows Security > Virus & threat protection > Manage settings > Tamper Protection.`n`nWrite the persist-off policy anyway?",
            'Tamper Protection is blocking persistence', 'YesNo', 'Warning')
        if ($go -ne 'Yes') {
            Open-WindowsSecurityThreatPage
            return
        }
    }
    else {
        $ok = [Windows.Forms.MessageBox]::Show(
            "Write a local policy so Defender real-time protection stays off after reboot?`n`nThis uses the official Windows Defender policy keys. It lowers protection on this PC until you click 'RTP ON' or 'Clear persist policy'.",
            'Confirm persistent RTP off', 'YesNo', 'Warning')
        if ($ok -ne 'Yes') { return }
    }
    Invoke-SecAction { Set-DefenderRealtimePersistent -Enabled $false } 'Persist-off policy written. Re-check status after a reboot.'
})

$btnRtpClearPolicy.Add_Click({
    Invoke-SecAction { Set-DefenderRealtimePersistent -Enabled $true } 'Persist-off policy cleared.'
})

$btnOpenSec.Add_Click({ Open-WindowsSecurityThreatPage })
$btnSecRefresh.Add_Click({ Update-SecurityPanel; $statLabel.Text = 'Security status refreshed.' })

$btnDisable.Add_Click({
    $sel = @(Get-SelectedItems)
    if ($sel.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Select one or more rows first.', 'Nothing selected', 'OK', 'Information') | Out-Null
        return
    }
    $ok = [Windows.Forms.MessageBox]::Show(
        "Disable $($sel.Count) selected item(s)?`n`nRegistry/folder items use the same on/off flag as Task Manager (reversible).`nTasks are disabled. Services are set to Disabled startup type.",
        'Confirm disable', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }

    $fail = 0
    foreach ($item in $sel) {
        if ($item.State -eq 'Disabled') { continue }
        if (-not (Confirm-RiskyChange -Item $item -Action 'disable')) { continue }
        try {
            Disable-StartupItem $item
        }
        catch {
            $fail++
            [Windows.Forms.MessageBox]::Show("Could not disable '$($item.Name)':`n$($_.Exception.Message)`n`nIf this is an HKLM / service / task item, relaunch as Administrator.", 'Disable failed', 'OK', 'Warning') | Out-Null
        }
    }
    Refresh-All
    $statLabel.Text = if ($fail) { "Disable finished with $fail error(s)." } else { 'Selected items disabled.' }
})

$btnEnable.Add_Click({
    $sel = @(Get-SelectedItems)
    if ($sel.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Select one or more rows first.', 'Nothing selected', 'OK', 'Information') | Out-Null
        return
    }
    $fail = 0
    foreach ($item in $sel) {
        try {
            Enable-StartupItem $item
        }
        catch {
            $fail++
            [Windows.Forms.MessageBox]::Show("Could not enable '$($item.Name)':`n$($_.Exception.Message)", 'Enable failed', 'OK', 'Warning') | Out-Null
        }
    }
    Refresh-All
    $statLabel.Text = if ($fail) { "Enable finished with $fail error(s)." } else { 'Selected items enabled.' }
})

$btnExport.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "startup-items-$(Get-Date -Format yyyyMMdd-HHmm).csv"
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try {
        Get-FilteredItems |
            Select-Object Name, Type, Scope, State, Publisher, Command, Location |
            Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        $statLabel.Text = "Exported to $($dlg.FileName)"
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export failed', 'OK', 'Error') | Out-Null
    }
})

$btnOpen.Add_Click({
    $sel = @(Get-SelectedItems)
    if ($sel.Count -eq 0) { return }
    $item = $sel[0]
    try {
        switch ($item.Meta.Kind) {
            'Registry' {
                $reg = $item.Meta.RegPath -replace '^HKCU:\\','HKEY_CURRENT_USER\' -replace '^HKLM:\\','HKEY_LOCAL_MACHINE\'
                $reg = $reg -replace '\\','\\'
                New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit' -Name LastKey -Value $reg -Force -ErrorAction SilentlyContinue | Out-Null
                Start-Process regedit.exe
            }
            'Folder' {
                $dir = Split-Path $item.Meta.FilePath -Parent
                Start-Process explorer.exe -ArgumentList "`"$dir`""
            }
            'Task' {
                Start-Process taskschd.msc
            }
            'Service' {
                Start-Process services.msc
            }
        }
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open failed', 'OK', 'Warning') | Out-Null
    }
})

$btnAdmin.Add_Click({
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try {
        [void][Diagnostics.Process]::Start($psi)
        $form.Close()
    }
    catch {
        $statLabel.Text = 'Elevation cancelled.'
    }
})

$grid.Add_CellDoubleClick({
    $sel = @(Get-SelectedItems)
    if ($sel.Count -eq 0) { return }
    $i = $sel[0]
    $text = @"
Name:      $($i.Name)
Type:      $($i.Type)
Scope:     $($i.Scope)
State:     $($i.State)
Publisher: $($i.Publisher)
Command:   $($i.Command)
Location:  $($i.Location)
"@
    [Windows.Forms.MessageBox]::Show($text, 'Item details', 'OK', 'Information') | Out-Null
})

$form.Add_Shown({ Refresh-All })

[void]$form.ShowDialog()
