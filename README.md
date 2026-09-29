# Windows Startup Manager

A PowerShell Windows Forms app that lists programs, tasks, and services set to run at boot or logon, and lets you enable or disable them. It also has on/off controls for Windows Firewall and Microsoft Defender real-time protection.

## Files

- `StartupManager.ps1` - the GUI
- `Run-StartupManager.bat` - double-click launcher

## Run it

1. Download the two files into the same folder.
2. Right-click `Run-StartupManager.bat` and choose **Run as administrator**.

Or from PowerShell:

```powershell
Unblock-File .\StartupManager.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\StartupManager.ps1
```

Administrator rights are required to change all-users registry keys, services, firewall, and Defender.

If Windows still blocks the script:

```powershell
Unblock-File .\StartupManager.ps1
```

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
