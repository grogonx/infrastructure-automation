# =============================================================================
# bulk_user_onboarding.ps1
# Description: Reads a CSV file of new employees and creates Active Directory
#              user accounts, sets passwords, assigns group memberships,
#              creates home directories, and sends a summary report.
# Author:      Joshua Harvey
#
# CSV Format (new_users.csv):
#   FirstName,LastName,Department,Title,Manager,Groups,OU
#   John,Smith,IT,Systems Engineer,jdoe,"IT-Staff;VPN-Users","OU=IT,DC=corp,DC=example,DC=com"
#
# Requirements:
#   - Run on a domain-joined machine with RSAT (AD PowerShell module)
#   - Run as a user with rights to create AD accounts
# =============================================================================

#Requires -Module ActiveDirectory

param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$DefaultPassword  = "Welcome1!ChangeMe",
    [string]$HomeDriveRoot    = "\\fileserver\homes",
    [string]$ReportPath       = "C:\Reports\Onboarding_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch]$WhatIf
)

# --- Setup ---
$ErrorActionPreference = "Continue"
$Report = [System.Collections.Generic.List[PSCustomObject]]::new()
$Created = 0; $Skipped = 0; $Failed = 0

$ReportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir | Out-Null
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Bulk User Onboarding"
Write-Host "  CSV    : $CsvPath"
Write-Host "  WhatIf : $($WhatIf.IsPresent)"
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================" -ForegroundColor Cyan

# --- Validate CSV ---
if (-not (Test-Path $CsvPath)) {
    Write-Host "[ERROR] CSV file not found: $CsvPath" -ForegroundColor Red
    exit 1
}

$Users = Import-Csv -Path $CsvPath
Write-Host "`n  Users to process: $($Users.Count)`n"

foreach ($User in $Users) {
    $FirstName  = $User.FirstName.Trim()
    $LastName   = $User.LastName.Trim()
    $Department = $User.Department.Trim()
    $Title      = $User.Title.Trim()
    $Manager    = $User.Manager.Trim()
    $Groups     = $User.Groups -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $OU         = $User.OU.Trim()

    # Build standard username: first initial + last name (e.g. jsmith)
    $Username   = ($FirstName.Substring(0,1) + $LastName).ToLower() -replace '[^a-z0-9]', ''
    $DisplayName = "$FirstName $LastName"
    $UPN         = "$Username@corp.example.com"
    $Email       = "$Username@example.com"
    $HomeDir     = "$HomeDriveRoot\$Username"

    Write-Host "  Processing: $DisplayName ($Username)" -NoNewline

    # --- Check if user already exists ---
    if (Get-ADUser -Filter { SamAccountName -eq $Username } -ErrorAction SilentlyContinue) {
        Write-Host " — [SKIP] Already exists" -ForegroundColor Yellow
        $Skipped++
        $Report.Add([PSCustomObject]@{
            Username    = $Username
            DisplayName = $DisplayName
            Status      = "Skipped"
            Notes       = "User already exists in AD"
        })
        continue
    }

    try {
        $SecurePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force

        $NewUserParams = @{
            SamAccountName        = $Username
            UserPrincipalName     = $UPN
            Name                  = $DisplayName
            GivenName             = $FirstName
            Surname               = $LastName
            DisplayName           = $DisplayName
            EmailAddress          = $Email
            Department            = $Department
            Title                 = $Title
            Path                  = $OU
            AccountPassword       = $SecurePassword
            ChangePasswordAtLogon = $true
            Enabled               = $true
            HomeDirectory         = $HomeDir
            HomeDrive             = "H:"
        }

        if ($Manager) {
            $ManagerObj = Get-ADUser -Filter { SamAccountName -eq $Manager } -ErrorAction SilentlyContinue
            if ($ManagerObj) { $NewUserParams["Manager"] = $ManagerObj.DistinguishedName }
        }

        if ($WhatIf) {
            Write-Host " — [WHATIF] Would create user" -ForegroundColor Cyan
        } else {
            New-ADUser @NewUserParams -ErrorAction Stop

            # Assign group memberships
            foreach ($Group in $Groups) {
                try {
                    Add-ADGroupMember -Identity $Group -Members $Username -ErrorAction Stop
                } catch {
                    Write-Warning "    Could not add $Username to group '$Group': $_"
                }
            }

            # Create home directory
            if (-not (Test-Path $HomeDir)) {
                New-Item -ItemType Directory -Path $HomeDir | Out-Null
                $Acl = Get-Acl $HomeDir
                $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $Username, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
                )
                $Acl.SetAccessRule($Rule)
                Set-Acl -Path $HomeDir -AclObject $Acl
            }

            Write-Host " — [CREATED]" -ForegroundColor Green
            $Created++
            $Report.Add([PSCustomObject]@{
                Username    = $Username
                DisplayName = $DisplayName
                Status      = "Created"
                Notes       = "Groups: $($Groups -join ', ')"
            })
        }
    } catch {
        Write-Host " — [FAILED] $_" -ForegroundColor Red
        $Failed++
        $Report.Add([PSCustomObject]@{
            Username    = $Username
            DisplayName = $DisplayName
            Status      = "Failed"
            Notes       = $_.Exception.Message
        })
    }
}

# --- Summary ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Summary"
Write-Host "  Created : $Created" -ForegroundColor Green
Write-Host "  Skipped : $Skipped" -ForegroundColor Yellow
Write-Host "  Failed  : $Failed"  -ForegroundColor $(if ($Failed -gt 0) { "Red" } else { "White" })
Write-Host "============================================" -ForegroundColor Cyan

$Report | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
Write-Host "`n  Report saved to: $ReportPath`n"
