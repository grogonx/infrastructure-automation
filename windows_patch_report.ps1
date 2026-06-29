# =============================================================================
# windows_patch_report.ps1
# Description: Queries one or more Windows servers for their patch status —
#              installed updates, pending reboots, last patch date, and
#              missing critical/security updates. Exports a CSV report.
# Author:      Joshua Harvey
#
# Usage:
#   # Run locally
#   .\windows_patch_report.ps1
#
#   # Run against a list of remote servers
#   .\windows_patch_report.ps1 -ComputerList "C:\servers.txt"
#
#   # Target specific servers
#   .\windows_patch_report.ps1 -Computers "server01","server02","server03"
# =============================================================================

param(
    [string[]]$Computers    = @($env:COMPUTERNAME),
    [string]  $ComputerList = "",
    [string]  $ReportPath   = "C:\Reports\Patch_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch]  $IncludeAll                     # Include all updates, not just recent
)

$ErrorActionPreference = "Continue"

$ReportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir | Out-Null
}

# Load servers from file if provided
if ($ComputerList -and (Test-Path $ComputerList)) {
    $Computers = Get-Content $ComputerList | Where-Object { $_.Trim() -ne "" }
}

$Report  = [System.Collections.Generic.List[PSCustomObject]]::new()
$Summary = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Windows Patch Status Report"
Write-Host "  Servers : $($Computers.Count)"
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================" -ForegroundColor Cyan

foreach ($Computer in $Computers) {
    $Computer = $Computer.Trim()
    Write-Host "`n  [$Computer]" -ForegroundColor White

    # Test connectivity
    if (-not (Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "    [OFFLINE] Cannot reach $Computer" -ForegroundColor Red
        $Summary.Add([PSCustomObject]@{
            ComputerName  = $Computer
            Status        = "Offline"
            OS            = "N/A"
            LastPatchDate = "N/A"
            PendingReboot = "N/A"
            UpdatesFound  = 0
            CriticalCount = 0
        })
        continue
    }

    try {
        $ScriptBlock = {
            param($IncludeAll)

            # OS info
            $OS = Get-CimInstance -ClassName Win32_OperatingSystem
            $OSName    = $OS.Caption
            $LastBoot  = $OS.LastBootUpTime

            # Pending reboot check
            $PendingReboot = $false
            $RebootKeys = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
                "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
            )
            foreach ($Key in $RebootKeys) {
                if (Test-Path $Key) { $PendingReboot = $true; break }
            }
            if (Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -ErrorAction SilentlyContinue) {
                $PendingReboot = $true
            }

            # Query Windows Update
            $UpdateSession   = New-Object -ComObject Microsoft.Update.Session
            $UpdateSearcher  = $UpdateSession.CreateUpdateSearcher()

            $SearchFilter = if ($IncludeAll) {
                "IsInstalled=0"
            } else {
                "IsInstalled=0 AND BrowseOnly=0"
            }

            $SearchResult = $UpdateSearcher.Search($SearchFilter)
            $Updates      = $SearchResult.Updates

            # Get last installed update
            $History = $UpdateSearcher.QueryHistory(0, 1)
            $LastPatch = if ($History.Count -gt 0) {
                $History.Item(0).Date.ToString("yyyy-MM-dd HH:mm")
            } else { "Unknown" }

            $UpdateList = @()
            $CriticalCount = 0

            for ($i = 0; $i -lt $Updates.Count; $i++) {
                $Update = $Updates.Item($i)
                $Severity = $Update.MsrcSeverity
                if ($Severity -in @("Critical", "Important")) { $CriticalCount++ }
                $UpdateList += [PSCustomObject]@{
                    Title        = $Update.Title
                    KB           = ($Update.KBArticleIDs | Out-String).Trim()
                    Severity     = $Severity
                    Category     = ($Update.Categories.Item(0).Name)
                    Size         = [math]::Round($Update.MaxDownloadSize / 1MB, 1)
                    Released     = $Update.LastDeploymentChangeTime.ToString("yyyy-MM-dd")
                }
            }

            return @{
                OS            = $OSName
                LastBoot      = $LastBoot.ToString("yyyy-MM-dd HH:mm")
                LastPatch     = $LastPatch
                PendingReboot = $PendingReboot
                Updates       = $UpdateList
                CriticalCount = $CriticalCount
            }
        }

        $Result = Invoke-Command -ComputerName $Computer -ScriptBlock $ScriptBlock `
                    -ArgumentList $IncludeAll.IsPresent -ErrorAction Stop

        $PendingColor = if ($Result.PendingReboot) { "Yellow" } else { "Green" }
        $CritColor    = if ($Result.CriticalCount -gt 0) { "Red" } else { "Green" }

        Write-Host "    OS            : $($Result.OS)"
        Write-Host "    Last Boot     : $($Result.LastBoot)"
        Write-Host "    Last Patch    : $($Result.LastPatch)"
        Write-Host "    Pending Reboot: $($Result.PendingReboot)" -ForegroundColor $PendingColor
        Write-Host "    Missing Updates: $($Result.Updates.Count) ($($Result.CriticalCount) critical/important)" -ForegroundColor $CritColor

        $Summary.Add([PSCustomObject]@{
            ComputerName   = $Computer
            Status         = "Online"
            OS             = $Result.OS
            LastPatchDate  = $Result.LastPatch
            PendingReboot  = $Result.PendingReboot
            UpdatesFound   = $Result.Updates.Count
            CriticalCount  = $Result.CriticalCount
        })

        foreach ($Update in $Result.Updates) {
            $Report.Add([PSCustomObject]@{
                ComputerName = $Computer
                KB           = $Update.KB
                Title        = $Update.Title
                Severity     = $Update.Severity
                Category     = $Update.Category
                SizeMB       = $Update.Size
                Released     = $Update.Released
            })
        }

    } catch {
        Write-Host "    [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $Summary.Add([PSCustomObject]@{
            ComputerName  = $Computer
            Status        = "Error"
            OS            = "N/A"
            LastPatchDate = "N/A"
            PendingReboot = "N/A"
            UpdatesFound  = 0
            CriticalCount = 0
        })
    }
}

# --- Export ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Summary"
$Summary | Format-Table -AutoSize
$Summary | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8

$DetailPath = $ReportPath -replace "\.csv$", "_details.csv"
if ($Report.Count -gt 0) {
    $Report | Export-Csv -Path $DetailPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Detail report  : $DetailPath"
}
Write-Host "  Summary report : $ReportPath"
Write-Host "============================================`n" -ForegroundColor Cyan
