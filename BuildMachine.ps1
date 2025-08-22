# BuildMachine.ps1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-file DSC setup: pre-install snapshot, WSL2, Docker Desktop, VS Code.

.PARAMETER EnableHyperV
  Switch to also enable Hyper-V (useful for Windows containers). Not required for Docker's WSL2 backend.

.PARAMETER SkipUbuntu
  Switch to skip installing the Ubuntu WSL distro.

.PARAMETER ImageBackupTarget
  Optional drive root (e.g. "E:\") for a full system image backup via wbAdmin BEFORE installs.
  If omitted, only a System Restore Point is created.
#>

param(
  [switch]$EnableHyperV,
  [switch]$SkipUbuntu,
  [string]$ImageBackupTarget
)

# --- Helpers -----------------------------------------------------------------
function Ensure-PSGalleryTrusted {
  try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch {}
}
function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Write-Host "Installing module: $Name ..."
    Install-Module -Name $Name -Force -Scope AllUsers -ErrorAction Stop
  }
}

# --- Prep: make sure Winget DSC resource is available ------------------------
Ensure-PSGalleryTrusted
Ensure-Module -Name WingetDsc

# --- LCM meta-config: allow reboots and resume -------------------------------
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

# --- Main configuration ------------------------------------------------------
configuration BuildWorkstation {
  param(
    [bool]   $EnableHyperV = $false,
    [bool]   $InstallUbuntu = $true,
    [string] $ImageBackupTarget
  )

  Import-DscResource -ModuleName PSDesiredStateConfiguration
  Import-DscResource -ModuleName WingetDsc

  # Common dependency chain builder: everything happens AFTER snapshot(s)
  $commonDepends = @('[Script]CreateRestorePoint')

  if ($ImageBackupTarget) { $commonDepends += '[Script]FullImageBackup' }

  Node 'localhost' {

    # Enable System Restore (System Protection) on C: so we can snapshot
    Script EnableSystemRestore {
      GetScript = { @{ Enabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'DisableSR' -ErrorAction SilentlyContinue).DisableSR } }
      TestScript = {
        try {
          $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'DisableSR' -ErrorAction Stop).DisableSR
          return ($v -eq 0)
        } catch { return $false }
      }
      SetScript = {
        Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'DisableSR' -Value 0 -Force
      }
    }

    # Create a pre-install restore point
    Script CreateRestorePoint {
      DependsOn = '[Script]EnableSystemRestore'
      GetScript  = { @{ RP = (Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object Description -eq 'Pre-DSC Snapshot') } }
      TestScript = {
        try {
          $rp = Get-ComputerRestorePoint -ErrorAction Stop | Where-Object Description -eq 'Pre-DSC Snapshot'
          return [bool]$rp
        } catch { return $false }
      }
      SetScript  = {
        # Allow immediate creation by disabling daily throttle (safe)
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -PropertyType DWord -Value 0 -Force | Out-Null
        Checkpoint-Computer -Description 'Pre-DSC Snapshot' -RestorePointType 'MODIFY_SETTINGS'
      }
    }

    # Optional: full image backup to external drive (takes time)
    if ($ImageBackupTarget) {
      Script FullImageBackup {
        DependsOn = '[Script]CreateRestorePoint'
        GetScript = { @{ Present = Test-Path (Join-Path $using:ImageBackupTarget 'WindowsImageBackup') } }
        TestScript = {
          if (-not (Test-Path $using:ImageBackupTarget)) { return $false }
          return Test-Path (Join-Path $using:ImageBackupTarget 'WindowsImageBackup')
        }
        SetScript = {
          wbAdmin start backup `
            -backupTarget:$using:ImageBackupTarget `
            -include:C: `
            -allCritical `
            -quiet
        }
      }
    }

    # Enable WSL
    WindowsOptionalFeature WSL {
      Name   = 'Microsoft-Windows-Subsystem-Linux'
      Ensure = 'Enable'
      DependsOn = $commonDepends
    }

    # Enable Virtual Machine Platform (WSL2 requirement)
    WindowsOptionalFeature VMPlatform {
      Name      = 'VirtualMachinePlatform'
      Ensure    = 'Enable'
      DependsOn = '[WindowsOptionalFeature]WSL'
    }

    # Optional: Hyper-V (helpful for Windows containers; not required for WSL2 backend)
    WindowsOptionalFeature HyperV {
      Name      = 'Microsoft-Hyper-V-All'
      Ensure    = if ($EnableHyperV) { 'Enable' } else { 'Disable' }
      DependsOn = '[WindowsOptionalFeature]VMPlatform'
    }

    # Ensure WSL default is version 2
    Script WSLDefaultV2 {
      DependsOn = '[WindowsOptionalFeature]VMPlatform'
      GetScript  = { @{ Status = (& wsl.exe --status 2>$null) } }
      TestScript = {
        try { & wsl.exe --status | Out-String | Select-String -Quiet 'Default Version:\s*2' }
        catch { $false }
      }
      SetScript  = { & wsl.exe --set-default-version 2 }
    }

    # (Optional) Install Ubuntu default distro
    if ($InstallUbuntu) {
      WinGetPackage Ubuntu {
        Id                      = 'Canonical.Ubuntu'
        Ensure                  = 'Present'
        AcceptPackageAgreements = $true
        InstallScope            = 'Machine'
        Source                  = 'winget'
        DependsOn               = '[Script]WSLDefaultV2'
      }
    }

    # Install Docker Desktop
    WinGetPackage DockerDesktop {
      Id                      = 'Docker.DockerDesktop'
      Ensure                  = 'Present'
      AcceptPackageAgreements = $true
      InstallScope            = 'Machine'
      Source                  = 'winget'
      DependsOn               = @('[Script]WSLDefaultV2','[WindowsOptionalFeature]HyperV')
    }

    # Install Visual Studio Code
    WinGetPackage VSCode {
      Id                      = 'Microsoft.VisualStudioCode'
      Ensure                  = 'Present'
      AcceptPackageAgreements = $true
      InstallScope            = 'Machine'
      Source                  = 'winget'
      DependsOn               = @('[Script]WSLDefaultV2')
    }
  }
}

# --- Compile & apply ---------------------------------------------------------
$OutRoot = 'C:\DSC'
New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null

# Configure LCM for auto-reboots & resume
SetLCM -OutputPath "$OutRoot\LCM"
Set-DscLocalConfigurationManager -Path "$OutRoot\LCM" -Verbose

# Compile main config with your chosen options
$installUbuntu = -not $SkipUbuntu
BuildWorkstation -EnableHyperV:([bool]$EnableHyperV) -InstallUbuntu:([bool]$installUbuntu) -ImageBackupTarget $ImageBackupTarget -OutputPath "$OutRoot\BuildWorkstation"

# Apply (will reboot as needed and resume)
Start-DscConfiguration -Path "$OutRoot\BuildWorkstation" -Force -Wait -Verbose

Write-Host "`nDone. After any reboots, verify with:"
Write-Host "  wsl --status"
Write-Host "  wsl -l -v"
Write-Host "  docker version"
Write-Host "  code --version"
