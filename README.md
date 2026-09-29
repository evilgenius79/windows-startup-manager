# Windows Startup Manager

A PowerShell Windows Forms app that lists programs, tasks, and services set to run at boot or logon, and lets you enable or disable them. It also has on/off controls for Windows Firewall and Microsoft Defender real-time protection.

## Download

Releases with `StartupManager.exe` are published from GitHub Actions:

https://github.com/evilgenius79/windows-startup-manager/releases

## Files

- `StartupManager.ps1` - the GUI
- `Run-StartupManager.bat` - double-click launcher
- `Build-Exe.ps1` - local wrapper that builds `dist\\StartupManager.exe`
- `.github/workflows/build-exe.yml` - builds the exe on GitHub and attaches it to a Release

## Run it

1. Download the files into the same folder.
2. Right-click `Run-StartupManager.bat` and choose **Run as administrator**.

Or from PowerShell:

```powershell
Unblock-File .\\StartupManager.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\\StartupManager.ps1
```

Administrator rights are required to change all-users registry keys, services, firewall, and Defender.

If Windows still blocks the script:

```powershell
Unblock-File .\\StartupManager.ps1
```

## GitHub-built exe

The Windows runner wraps the script with [ps2exe](https://www.powershellgallery.com/packages/ps2exe) and attaches `StartupManager.exe` to a Release.

### Publish a release

1. Open [Actions](https://github.com/evilgenius79/windows-startup-manager/actions).
2. Select **Build exe**.
3. Click **Run workflow**.
4. Leave the tag as `v1.0.0` or set a new tag such as `v1.0.1`.
5. After the job finishes, the exe is on [Releases](https://github.com/evilgenius79/windows-startup-manager/releases).

Or push a version tag:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

A manual run with a blank tag only uploads an Actions artifact. It does not create a Release.

## Build an exe locally

```powershell
Unblock-File .\\Build-Exe.ps1
powershell -ExecutionPolicy Bypass -File .\\Build-Exe.ps1
```

That creates `dist\\StartupManager.exe` and requests Administrator on launch (UAC prompt).

Optional icon: put `StartupManager.ico` in the repo folder before building.

Notes:

- First run may show a SmartScreen warning because the exe is unsigned.
- Some antivirus tools flag PS2EXE wrappers generically. That is a known pattern, not proof the file is malware.
- To build without the admin manifest: `.\\Build-Exe.ps1 -NoAdminManifest`

## What it shows

- Registry `Run` and `RunOnce` keys (current user, all users, 32-bit)
- Current-user and all-users Startup folders
- Scheduled tasks with At startup or At logon triggers
- Services set to Automatic or Automatic (Delayed Start)

Microsoft services and Microsoft scheduled tasks are hidden by default. Uncheck those boxes to see them.

## Disable / enable

- Registry and folder items use the same `StartupApproved` flag Task Manager uses (reversible)
- Startup folder shortcuts can also be renamed to `*.disabled`
- Scheduled tasks are disabled or enabled
- Services are set to Disabled or Automatic

Do not disable core Windows services.

## Firewall and Defender

The bottom panel can:

- Turn Windows Firewall on or off per profile (Domain, Private, Public)
- Turn Defender real-time protection off until reboot
- Write a local policy so real-time protection stays off after reboot
- Clear that policy and turn protection back on

If real-time protection turns itself back on after reboot, **Tamper Protection** is still on. Turn that off in Windows Security first:

`Virus and threat protection` > `Manage settings` > `Tamper Protection`

This tool does not bypass Tamper Protection.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 (built in) or newer
- Administrator for system-wide changes

## Notes

This is not a full replacement for [Sysinternals Autoruns](https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns). Autoruns still covers extra autostart locations such as drivers, Explorer extensions, and image hijacks.

Turning off firewall or antivirus reduces protection on that PC. Use it for troubleshooting, then turn protection back on.
