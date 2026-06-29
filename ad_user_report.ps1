# =============================================================================
# ad_user_report.ps1
# Description: Audits Active Directory for inactive accounts, accounts without
#              expiry, disabled accounts still in active OUs, and users with
#              passwords that never expire. Exports a CSV report.
# Author:      Joshua Harvey
#
# Requirements:
#   - Run on a domain-joined machine with RSAT (AD PowerShell module)
#   - Run as a user with read access to AD
# =============================================================================

#Requires -Module ActiveDirectory

# --- Configuration ---
$InactiveDays     = 90
$ReportPath       = "C:\Reports\AD_User_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$SearchBase       = "DC=corp,DC=example,DC=com"   # Update to your domain
$CutoffDate       = (Get-Date).AddDays(-$InactiveDays)

# Ensure report directory exists
$ReportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir | Out-Null
    Write-Host "[INFO] Created report directory: $ReportDir" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Active Directory User Audit"
Write-Host "  Domain  : $SearchBase"
Write-Host "  Run at  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================" -ForegroundColor Cyan

$Report = [System.Collections.Generic.List[PSCustomObject]]::new()
$Counts = @{ Inactive = 0; NeverExpires = 0; NoExpiry = 0; Disabled = 0 }

try {
    $Users = Get-ADUser -Filter * -SearchBase $SearchBase -Properties `
        DisplayName, SamAccountName, EmailAddress, LastLogonDate, `
        PasswordNeverExpires, AccountExpirationDate, Enabled, `
        DistinguishedName, Department, Title -ErrorAction Stop
}
catch {
    Write-Host "[ERROR] Failed to query Active Directory: $_" -ForegroundColor Red
    exit 1
}

Write-Host "`n  Total users found: $($Users.Count)" -ForegroundColor White

foreach ($User in $Users) {
    $Flags = [System.Collections.Generic.List[string]]::new()

    # --- Check: Inactive ---
    $LastLogon = $User.LastLogonDate
    if ($null -eq $LastLogon -or $LastLogon -lt $CutoffDate) {
        $Flags.Add("Inactive ($InactiveDays+ days)")
        $Counts.Inactive++
    }

    # --- Check: Password never expires ---
    if ($User.PasswordNeverExpires -and $User.Enabled) {
        $Flags.Add("Password Never Expires")
        $Counts.NeverExpires++
    }

    # --- Check: No account expiry set ---
    if ($null -eq $User.AccountExpirationDate -and $User.Enabled) {
        $Flags.Add("No Account Expiry Set")
        $Counts.NoExpiry++
    }

    # --- Check: Disabled accounts ---
    if (-not $User.Enabled) {
        $Flags.Add("Account Disabled")
        $Counts.Disabled++
    }

    # Only add to report if there are flags
    if ($Flags.Count -gt 0) {
        $Entry = [PSCustomObject]@{
            DisplayName           = $User.DisplayName
            Username              = $User.SamAccountName
            Email                 = $User.EmailAddress
            Department            = $User.Department
            Title                 = $User.Title
            Enabled               = $User.Enabled
            LastLogonDate         = if ($LastLogon) { $LastLogon.ToString("yyyy-MM-dd") } else { "Never" }
            PasswordNeverExpires  = $User.PasswordNeverExpires
            AccountExpirationDate = if ($User.AccountExpirationDate) {
                                        $User.AccountExpirationDate.ToString("yyyy-MM-dd")
                                    } else { "Not Set" }
            Flags                 = ($Flags -join " | ")
        }
        $Report.Add($Entry)
    }
}

# --- Console Summary ---
Write-Host ""
Write-Host "  Results:" -ForegroundColor Yellow
Write-Host "    Inactive accounts ($InactiveDays+ days) : $($Counts.Inactive)"
Write-Host "    Password never expires                  : $($Counts.NeverExpires)"
Write-Host "    No account expiry set                   : $($Counts.NoExpiry)"
Write-Host "    Disabled accounts                       : $($Counts.Disabled)"
Write-Host "    Total flagged users                     : $($Report.Count)"

# --- Export Report ---
if ($Report.Count -gt 0) {
    $Report | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "  [OK] Report exported to: $ReportPath" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  [OK] No issues found. No report generated." -ForegroundColor Green
}

Write-Host "============================================`n" -ForegroundColor Cyan
