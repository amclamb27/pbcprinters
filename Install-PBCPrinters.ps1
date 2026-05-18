<#
.SYNOPSIS
    PBC Intern Printer Setup — Windows
.DESCRIPTION
    Layer27 Technology Services
    Installs Providence Baptist Church printers on personal Windows laptops that
    are NOT enrolled in NinjaOne RMM (summer interns, contractors, guests).

    Uses a built-in Microsoft printer driver (no Toshiba driver download
    required). Idempotent — safe to re-run.

    REQUIRES: PowerShell launched as Administrator.

.PARAMETER Action
    'install' (default) or 'remove'.

.EXAMPLE
    # On-site (recommended one-liner, in an elevated PowerShell window):
    irm https://raw.githubusercontent.com/<ORG>/<REPO>/main/windows/Install-PBCPrinters.ps1 | iex

.EXAMPLE
    # From USB:
    powershell -ExecutionPolicy Bypass -File .\Install-PBCPrinters.ps1
.EXAMPLE
    # Remove all PBC printers:
    powershell -ExecutionPolicy Bypass -File .\Install-PBCPrinters.ps1 -Action remove
#>

param(
    [ValidateSet('install','remove')]
    [string]$Action = 'install'
)

$ErrorActionPreference = 'Continue'
$LogPath = "$env:TEMP\pbc-printer-install.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts [$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

# ----- Admin check ------------------------------------------------------------
$currentUser = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host ""
    Write-Host "How to fix:" -ForegroundColor Yellow
    Write-Host "  1. Press the Windows key"
    Write-Host "  2. Type:  PowerShell"
    Write-Host "  3. Right-click 'Windows PowerShell' -> 'Run as administrator'"
    Write-Host "  4. Click 'Yes' on the UAC prompt"
    Write-Host "  5. Paste the install command again"
    Write-Host ""
    if ($Host.Name -eq 'ConsoleHost') { Read-Host "Press Enter to exit" }
    exit 1
}

Write-Log "=== PBC printer $Action starting on $env:COMPUTERNAME ==="

# ----- Printer definitions ----------------------------------------------------
# Keep in sync with the Mac script and IT Glue.
$Printers = @(
    [PSCustomObject]@{ Name = 'Toshiba B547 (Admin)';      IP = '10.5.1.17'  }
    [PSCustomObject]@{ Name = 'Toshiba A214 (Ministry)';   IP = '10.40.3.13' }
    [PSCustomObject]@{ Name = 'Toshiba A510 (Ministry)';   IP = '10.5.1.19'  }
    [PSCustomObject]@{ Name = 'Toshiba A616 (WC-Tech)';    IP = '10.40.3.12' }
    [PSCustomObject]@{ Name = 'Toshiba B135 (Admin)';      IP = '10.1.1.51'  }
    [PSCustomObject]@{ Name = 'Toshiba C181 (WC-Tech)';    IP = '10.40.3.15' }
)

# ----- Driver selection --------------------------------------------------------
function Get-BestDriver {
    # Try PostScript-capable drivers first; fall back to generic.
    # The Toshiba e-STUDIO line supports PostScript so PS Class Driver
    # gives the best results without installing the Toshiba UPD.
    $preferences = @(
        'Microsoft PS Class Driver',
        'Microsoft IPP Class Driver',
        'Microsoft enhanced Point and Print compatibility driver',
        'Generic / Text Only'
    )
    foreach ($name in $preferences) {
        if (Get-PrinterDriver -Name $name -ErrorAction SilentlyContinue) {
            return $name
        }
    }
    # Last resort — try to add the PS Class Driver from the driver store
    try {
        Add-PrinterDriver -Name 'Microsoft PS Class Driver' -ErrorAction Stop
        return 'Microsoft PS Class Driver'
    } catch {
        return $null
    }
}

# ----- Install action ---------------------------------------------------------
function Invoke-Install {
    $driver = Get-BestDriver
    if (-not $driver) {
        Write-Log "No usable printer driver found on this system." 'ERROR'
        if ($Host.Name -eq 'ConsoleHost') { Read-Host "Press Enter to exit" }
        exit 2
    }
    Write-Log "Using driver: $driver"
    Write-Host ""

    $added = 0; $skipped = 0; $failed = 0

    foreach ($p in $Printers) {
        $portName = "TCP_" + ($p.IP.Replace('.','_'))

        # Port (idempotent)
        try {
            if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
                Add-PrinterPort -Name $portName -PrinterHostAddress $p.IP -ErrorAction Stop
                Write-Log "Created port $portName ($($p.IP))"
            }
        } catch {
            Write-Log "Port create failed for $($p.Name): $($_.Exception.Message)" 'ERROR'
            $failed++
            continue
        }

        # Printer (idempotent)
        try {
            if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
                Write-Log "SKIP  — '$($p.Name)' already installed"
                $skipped++
            } else {
                Add-Printer -Name $p.Name -PortName $portName -DriverName $driver -ErrorAction Stop
                Write-Log "ADDED — $($p.Name) ($($p.IP))" 'OK'
                $added++
            }
        } catch {
            Write-Log "Install failed for $($p.Name): $($_.Exception.Message)" 'ERROR'
            $failed++
        }
    }

    Write-Host ""
    Write-Log "Summary: $added added, $skipped already present, $failed failed"
    Write-Host ""
    if ($failed -eq 0) {
        Write-Host "All Providence Baptist Church printers are now available." -ForegroundColor Green
        Write-Host "  Open any document -> File -> Print -> choose a printer."
        Write-Host ""
        Write-Host "  Log: $LogPath"
    } else {
        Write-Host "Some printers failed to install. See $LogPath for details." -ForegroundColor Yellow
    }
}

# ----- Remove action ----------------------------------------------------------
function Invoke-Remove {
    $removed = 0
    foreach ($p in $Printers) {
        if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
            try {
                Remove-Printer -Name $p.Name -ErrorAction Stop
                Write-Log "REMOVED — $($p.Name)" 'OK'
                $removed++
            } catch {
                Write-Log "Remove failed for $($p.Name): $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    # Clean up orphaned TCP ports
    foreach ($p in $Printers) {
        $portName = "TCP_" + ($p.IP.Replace('.','_'))
        $portInUse = Get-Printer | Where-Object { $_.PortName -eq $portName }
        if (-not $portInUse) {
            if (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue) {
                Remove-PrinterPort -Name $portName -ErrorAction SilentlyContinue
                Write-Log "REMOVED port $portName"
            }
        }
    }
    Write-Host ""
    Write-Log "Removal complete — $removed printer(s) removed."
}

# ----- Dispatch ---------------------------------------------------------------
switch ($Action) {
    'install' { Invoke-Install }
    'remove'  { Invoke-Remove }
}

if ($Host.Name -eq 'ConsoleHost' -and $MyInvocation.InvocationName -ne '&') {
    # Pause only if launched directly (file/USB), not via irm | iex pipeline
    if ($MyInvocation.MyCommand.Path) {
        Write-Host ""
        Read-Host "Press Enter to close"
    }
}
