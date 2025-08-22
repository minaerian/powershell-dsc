# BuildMachine.ps1 — DSC + winget (WSL2 backend, Docker Desktop, VS Code)
#Requires -RunAsAdministrator
<#
USAGE (Admin Windows PowerShell 5.1):
  Set-ExecutionPolicy -Scope Process Bypass -Force
  Unblock-File .\BuildMachine.ps1
  .\BuildMachine.ps1 -ImageBackupTarget "D:\"          # optional full image backup
  .\BuildMachine.ps1                                    # no image backup

PARAMS:
  -EnableHyperV       Enable Hyper-V (only needed for Windows containers)
  -SkipUbuntu         Don’t install the Ubuntu WSL distro
  -ImageBackupTarget  Drive root for full system image backup (e.g., "D:\")
  -ForceDockerWSL2    After install, force Docker Desktop to use WSL 2 backend (best effort)
#>

param(
  [switch]$EnableHyperV,
  [switch]$SkipUbuntu,
  [string]$ImageBackupTarget,
  [switch]$ForceDockerWSL2
)

# ----------------------- Helpers -----------------------
function Ensure-WinRM {
  # Works even if active network is Public; firewall scoped to LocalSubnet
  try { Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null } catch {}
  try {
    $rules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
    if ($rules) {
      $httpIn = $rules | Where-Object { $_.DisplayName -like "*(HTTP-In)*" }
      if ($httpIn) { $httpIn | Set-NetFirewallRule -Enabled True -Profile Any -RemoteAddress LocalSubnet | Out-Null }
    }
  } catch {}
  try {
    $svc = Get-Service WinRM -ErrorAction Stop
    if ($svc.StartType -ne 'Automatic') { Set-Service WinRM -StartupType Automatic }
    if ($svc.Status -ne 'Running') { Start-Service WinRM }
  } catch {}
}

function Test-WinGetPresent { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }
function Ensure-WinGetSources { try { winget source update --accept-source-agreements | Out-Null } catch {} }

function Test-WingetInstalled {
  param([Parameter(Mandatory)][string]$Id)
  try {
    $o = winget list --id $Id --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and $o -match [regex]::Escape($Id)) { return $true }
  } catch {}
  return $false
}

function Winget-Install-IfMissing {
  param(
    [Parameter(Mandatory)][string]$Id,
    [string]$ExtraArgs = ""
  )
  if (Test-WingetInstalled -Id $Id) { Write-Host "$Id already installed."; return }
  Write-Host "Installing $Id via winget..."
  $args = @('install','-e','--id',$Id,'--source','winget','--accept-package-agreements','--accept-source-agreements','--silent','--scope','machine')
  if ($ExtraArgs) { $args += $ExtraArgs.Split(' ') }
  winget @args
  if ($LASTEXITCODE -ne 0) { throw "winget failed for $Id (exit $LASTEXITCODE)." }
}

function Force-Docker-WSL2-Backend {
  # Best-effort: flip user settings to WSL engine; run AFTER Docker Desktop is installed (and ideally launched once)
  try {
    $dockerAppData = Join-Path $env:APPDATA 'Docker'
    New-Item -ItemType Directory -Path $dockerAppData -Force | Out-Null
    $targets = @('settings-store.json','settings.json') | ForEach-Object { Join-Path $dockerAppData $_ }

    $payload = @{
      wslEngineEnabled     = $true
      useWindowsContainers = $false
      linuxVM              = @{ wslEngineEnabled = $true }
    }

    foreach ($file in $targets) {
      if (Test-Path $file) {
        $j = Get-Content $file -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $j) { $j = [ordered]@{} }
        $j.wslEngineEnabled = $true
        $j.useWindowsContainers = $false
        if (-not $j.PSObject.Properties.Match('linuxVM')) { $j | Add-Member -NotePropertyName linuxVM -NotePropertyValue (@{}) }
        $j.linuxVM.wslEngineEnabled = $true
        ($j | ConvertTo-Json -Depth 10) | Set-Content $file -Encoding UTF8
      } else {
        ($payload | ConvertTo-Json -Depth 5) | Set-Content $file -Encoding UTF8
      }
    }
    Write-Host "Docker Desktop settings updated to prefer WSL 2 backend (if supported)."
  } catch {
    Write-Warning "Could not update Docker Desktop settings automatically: $($_.Exception.Message)"
  }
}

function Get-UbuntuDistroName {
  try {
    $list = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -eq 0) {
      $name = ($list | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1)
      if ($name) { return $name.Trim() }
    }
  } catch {}
  return $null
}

function Ensure-UbuntuWSL {
  # Installs Ubuntu via WSL (not winget). Tries common names; handles reboot-required scenarios.
  param([string[]]$Candidates = @("Ubuntu","Ubuntu-24.04","Ubuntu-22.04"))
  $existing = Get-UbuntuDistroName
  if ($existing) { Write-Host "$existing already installed in WSL."; return $existing }

  foreach ($name in $Candidates) {
    Write-Host "Installing $name via WSL..."
    & wsl.exe --install -d $name
    $code = $LASTEXITCODE
    Start-Sleep -Seconds 2
    $post = Get-UbuntuDistroName
    if ($code -eq 0 -and $post) {
      try { & wsl.exe --set-default $post } catch {}
      Write-Host "$post installed and set as default."
      return $post
    }
    if ($code -ne 0) {
      Write-Warning "WSL returned exit code $code while installing $name. If it prompted for a reboot, reboot and run this script again."
    }
  }
  Write-Warning "Could not verify Ubuntu registration. You can also install from Microsoft Store or run: wsl --install -d Ubuntu (then reboot)."
  return $null
}

function Update-WSL {
  Write-Host "Updating WSL kernel..."
  try { & wsl.exe --update --web-download } catch { & wsl.exe --update }
  & wsl.exe --shutdown
  Write-Host "WSL updated and shut down."
}

function Update-Ubuntu {
  param([string]$DistroName)
  if (-not $DistroName) { $DistroName = Get-UbuntuDistroName }
  if (-not $DistroName) { Write-Warning "No Ubuntu distro detected yet; skipping package update."; return }

  Write-Host "Updating packages inside $DistroName (this may take a while)..."
  try {
    & wsl.exe -d $DistroName -u root -- bash -lc "apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove && apt-get -y autoclean"
    if ($LASTEXITCODE -eq 0) {
      Write-Host "Ubuntu packages updated."
    } else {
      Write-Warning "Package update in $DistroName returned exit code $LASTEXITCODE. Open the distro once to finish setup, then re-run this script with -SkipUbuntu."
    }
  } catch {
    Write-Warning "Could not run package update inside ${DistroName}: $($_.Exception.Message)"
  }
}

# ----------------------- LCM meta-config -----------------------
[DSCLocalConfigurationManager()]
configuration SetLCM {
  Node 'localhost' {
    Settings {
      RefreshMode        = 'Push'
      ConfigurationMode  = 'ApplyOnly'
      RebootNodeIfNeeded = $true
      ActionAfterReboot  = 'ContinueConfiguration'
    }
  }
}

# ----------------------- Main DSC config -----------------------
configuration BuildWorkstation {
  param(
    [bool]$EnableHyperV = $false,
    [bool]$InstallUbuntu = $true,
    [string]$ImageBackupTarget
  )

  Import-DscResource -ModuleName PSDesiredStateConfiguration

  Node 'localhost' {

    # Enable System Restore (tolerate missing key/value)
    Script EnableSystemRestore {
      GetScript  = {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'DisableSR' -ErrorAction SilentlyContinue
        @{ Enabled = if ($null -ne $reg -and $reg.PSObject.Properties.Name -contains 'DisableSR') { $reg.DisableSR } else { $null } }
      }
      TestScript = {
        try {
          $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'DisableSR' -ErrorAction SilentlyContinue
          if ($null -eq $reg -or -not ($reg.PSObject.Properties.Name -contains 'DisableSR')) { return $false }
          return ($reg.DisableSR -eq 0)
        } catch { return $false }
      }
      SetScript  = {
        Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'DisableSR' -Value 0 -Force
      }
    }

    # Create a pre-install restore point
    Script CreateRestorePoint {
      DependsOn = '[Script]EnableSystemRestore'
      GetScript  = {
        @{ RP = (Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
                 Where-Object { $_.Description -eq 'Pre-DSC Snapshot' }) }
      }
      TestScript = {
        try {
          $rp = Get-ComputerRestorePoint -ErrorAction Stop |
                  Where-Object { $_.Description -eq 'Pre-DSC Snapshot' }
          return [bool]$rp
        } catch { return $false }
      }
      SetScript  = {
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
          -Name 'SystemRestorePointCreationFrequency' -PropertyType DWord -Value 0 -Force | Out-Null
        Checkpoint-Computer -Description 'Pre-DSC Snapshot' -RestorePointType 'MODIFY_SETTINGS'
      }
    }

    # Optional: full image backup to external drive BEFORE changes (fixed -and)
    if ($ImageBackupTarget) {
      Script FullImageBackup {
        DependsOn = '[Script]CreateRestorePoint'
        GetScript = { @{ Done = Test-Path (Join-Path $using:ImageBackupTarget 'WindowsImageBackup') } }
        TestScript = {
          try {
            (Test-Path $using:ImageBackupTarget) -and (Test-Path (Join-Path $using:ImageBackupTarget 'WindowsImageBackup'))
          } catch { $false }
        }
        SetScript  = {
          wbAdmin start backup `
            -backupTarget:$using:ImageBackupTarget `
            -include:C: `
            -allCritical `
            -quiet
        }
      }
    }

    # Enable WSL + VM Platform (WSL2 requirement)
    WindowsOptionalFeature WSL {
      Name      = 'Microsoft-Windows-Subsystem-Linux'
      Ensure    = 'Enable'
      DependsOn = @('[Script]CreateRestorePoint')
    }

    WindowsOptionalFeature VMPlatform {
      Name      = 'VirtualMachinePlatform'
      Ensure    = 'Enable'
      DependsOn = '[WindowsOptionalFeature]WSL'
    }

    # Optional: Hyper-V (NOT required for Docker’s WSL2 backend)
    WindowsOptionalFeature HyperV {
      Name      = 'Microsoft-Hyper-V-All'
      Ensure    = if ($EnableHyperV) { 'Enable' } else { 'Disable' }
      DependsOn = '[WindowsOptionalFeature]VMPlatform'
    }

    # Make WSL2 the default
    Script WSLDefaultV2 {
      DependsOn = '[WindowsOptionalFeature]VMPlatform'
      GetScript  = { @{ Status = (& wsl.exe --status 2>$null) } }
      TestScript = { try { (& wsl.exe --status | Out-String) -match 'Default Version:\s*2' } catch { $false } }
      SetScript  = { & wsl.exe --set-default-version 2 }
    }
  }
}

# ----------------------- Apply DSC -----------------------
Ensure-WinRM

$OutRoot = 'C:\DSC'
New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null

SetLCM -OutputPath "$OutRoot\LCM"
Set-DscLocalConfigurationManager -Path "$OutRoot\LCM" -Verbose

$installUbuntu = -not $SkipUbuntu
BuildWorkstation -EnableHyperV:([bool]$EnableHyperV) -InstallUbuntu:([bool]$installUbuntu) -ImageBackupTarget $ImageBackupTarget -OutputPath "$OutRoot\BuildWorkstation"
Start-DscConfiguration -Path "$OutRoot\BuildWorkstation" -Force -Wait -Verbose
Write-Host "`nDSC phase complete."

# ----------------------- Auto-update WSL + Ubuntu -----------------------
Update-WSL

$UbuntuName = $null
if ($installUbuntu) { $UbuntuName = Ensure-UbuntuWSL }
if ($UbuntuName) { Update-Ubuntu -DistroName $UbuntuName }

# ----------------------- Apps via winget -----------------------
if (-not (Test-WinGetPresent)) { throw "winget.exe not found. Install 'App Installer' from Microsoft Store, then rerun this script." }
Ensure-WinGetSources
Winget-Install-IfMissing -Id "Docker.DockerDesktop"
Winget-Install-IfMissing -Id "Microsoft.VisualStudioCode"

if ($ForceDockerWSL2) { Force-Docker-WSL2-Backend }

# ----------------------- Final tips -----------------------
Write-Host ""
Write-Host "Verify:"
Write-Host "  wsl --status     (should show 'Default Version: 2')"
Write-Host "  wsl -l -v        (Ubuntu should show Version 2 after first launch)"
Write-Host "  docker version"
Write-Host "  code --version"
Write-Host ""
Write-Host "If 'wsl --install' asked for a reboot, reboot now, then:"
Write-Host "  wsl -l -v        (ensure Ubuntu is listed)"
Write-Host "  wsl --set-default Ubuntu"
Write-Host "Open Docker Desktop and enable WSL integration with Ubuntu if prompted."
Write-Host ""
Write-Host "For best performance with Docker WSL2, keep your project files inside WSL (e.g., \\wsl$\Ubuntu\home\<you>)."
