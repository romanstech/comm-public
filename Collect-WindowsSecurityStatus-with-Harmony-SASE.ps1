#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateRange(1, 365)]
    [int]$EventDays = 14
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Get-DownloadsFolder {
    try {
        $shellFoldersPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $downloadsId = '{374DE290-123F-4565-9164-39C4925E467B}'
        $path = (Get-ItemProperty -Path $shellFoldersPath -Name $downloadsId -ErrorAction Stop).$downloadsId
        return [Environment]::ExpandEnvironmentVariables($path)
    }
    catch {
        return (Join-Path $env:USERPROFILE 'Downloads')
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Get-DownloadsFolder
}

try {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
}
catch {
    Write-Error "Unable to create the report directory: $($_.Exception.Message)"
    exit 1
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeComputerName = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '_')
$reportPath = Join-Path $OutputDirectory "Windows-Security-Report-${safeComputerName}-${timestamp}.txt"
$osqueryExe = 'C:\Program Files\Perimeter 81\bin\osqueryi.exe'
$report = New-Object System.Collections.Generic.List[string]
$collectionStep = 0
$totalCollectionSteps = 12

function Add-Line {
    param([AllowEmptyString()][string]$Text = '')
    $script:report.Add($Text)
}

function Add-Section {
    param([Parameter(Mandatory)][string]$Title)
    Add-Line
    Add-Line ('=' * 80)
    Add-Line $Title
    Add-Line ('=' * 80)
}

function Add-CommandResult {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Command
    )

    $script:collectionStep++
    $stepNumber = $script:collectionStep
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ("[{0}/{1}] {2} ..." -f $stepNumber, $script:totalCollectionSteps, $Title) -ForegroundColor Cyan

    Add-Section $Title
    try {
        $result = & $Command 2>&1
        if ($null -eq $result -or @($result).Count -eq 0) {
            Add-Line '[No data found]'
        }
        else {
            Add-Line (($result | Out-String -Width 300).TrimEnd())
        }
    }
    catch {
        Add-Line ("ERROR: {0}" -f $_.Exception.Message)
    }
    finally {
        $stopwatch.Stop()
        Write-Host ("      Completed in {0:N1} seconds" -f $stopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch {
    $isAdmin = $false
}

Add-Line 'WINDOWS SECURITY DIAGNOSTIC REPORT'
Add-Line ("Created:                  {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
Add-Line ("Computer:                 {0}" -f $env:COMPUTERNAME)
Add-Line ("User:                     {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Add-Line ("PowerShell:               {0}" -f $PSVersionTable.PSVersion)
Add-Line ("Running as administrator: {0}" -f $isAdmin)
Add-Line 'Collection mode: read-only; this script does not change security settings.'

Write-Host
Write-Host 'Windows Security Diagnostic Collector' -ForegroundColor Green
Write-Host ("Computer: {0}    User: {1}\{2}" -f $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME)
Write-Host ("Collecting {0} diagnostic sections. Please wait..." -f $totalCollectionSteps)
Write-Host

Add-CommandResult 'HARMONY SASE CLIENT VERSION' {
    Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match 'Harmony SASE|Perimeter 81'
        } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Format-Table -AutoSize
}

Add-CommandResult 'WINDOWS INFORMATION' {
    Get-CimInstance Win32_OperatingSystem -ErrorAction Stop |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime

    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop |
        Select-Object DisplayVersion, CurrentBuildNumber, UBR
}

Add-CommandResult 'OSQUERY: WINDOWS SECURITY CENTER AND PRODUCTS' {
    if (-not (Test-Path -LiteralPath $osqueryExe)) {
        throw "osqueryi.exe was not found: $osqueryExe"
    }

    @'
SELECT * FROM windows_security_center;
SELECT * FROM windows_security_products;
'@ | & $osqueryExe
}

Add-CommandResult 'ANTIVIRUS PRODUCTS REGISTERED WITH WINDOWS SECURITY CENTER' {
    Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop |
        Select-Object displayName, productState, pathToSignedProductExe, pathToSignedReportingExe
}

Add-CommandResult 'SECURITY CENTER ANTIVIRUS STATE (DECODED)' {
    Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop |
        ForEach-Object {
            $hex = '{0:x6}' -f $_.productState
            [PSCustomObject]@{
                Product             = $_.displayName
                RealTimeOn          = ($hex.Substring(2, 2) -in '10', '11')
                DefinitionsUpToDate = ($hex.Substring(4, 2) -eq '00')
                RawState            = $hex
            }
        } | Format-Table -AutoSize
}

Add-CommandResult 'SECURITY CENTER ANTIVIRUS PRODUCTS (FULL DATA)' {
    Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop |
        Format-List *
}

Add-CommandResult 'MICROSOFT DEFENDER SUMMARY' {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        throw 'The Get-MpComputerStatus command is not available.'
    }

    Get-MpComputerStatus -ErrorAction Stop |
        Select-Object AMRunningMode,
                      AMServiceEnabled,
                      AntivirusEnabled,
                      AntispywareEnabled,
                      RealTimeProtectionEnabled,
                      BehaviorMonitorEnabled,
                      IoavProtectionEnabled,
                      NISEnabled,
                      OnAccessProtectionEnabled,
                      IsTamperProtected,
                      AntivirusSignatureVersion,
                      AntivirusSignatureLastUpdated,
                      AntivirusSignatureAge,
                      AMEngineVersion,
                      AMProductVersion,
                      QuickScanStartTime,
                      QuickScanEndTime,
                      QuickScanAge,
                      FullScanStartTime,
                      FullScanEndTime,
                      FullScanAge |
        Format-List
}

Add-CommandResult 'MICROSOFT DEFENDER (FULL STATUS)' {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        throw 'The Get-MpComputerStatus command is not available.'
    }

    Get-MpComputerStatus -ErrorAction Stop | Format-List *
}

Add-CommandResult 'WINDOWS SECURITY SERVICES' {
    Get-CimInstance Win32_Service -Filter "Name='WinDefend' OR Name='SecurityHealthService' OR Name='wscsvc'" -ErrorAction Stop |
        Select-Object Name, DisplayName, State, StartMode, Status |
        Format-Table -AutoSize
}

Add-CommandResult 'RECENT DEFENDER THREAT DETECTIONS' {
    if (-not (Get-Command Get-MpThreatDetection -ErrorAction SilentlyContinue)) {
        throw 'The Get-MpThreatDetection command is not available.'
    }

    Get-MpThreatDetection -ErrorAction Stop |
        Sort-Object InitialDetectionTime -Descending |
        Select-Object -First 20 InitialDetectionTime,
                                LastThreatStatusChangeTime,
                                ThreatID,
                                ActionSuccess,
                                CurrentThreatExecutionStatusID,
                                Resources |
        Format-List
}

Add-CommandResult "DEFENDER EVENTS FROM THE LAST $EventDays DAYS" {
    $importantIds = 1000, 1001, 1002, 1005, 1116, 1117, 1118, 1119, 2000, 2001, 5000, 5001, 5004, 5007
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-Windows Defender/Operational'
        StartTime = (Get-Date).AddDays(-$EventDays)
        Id        = $importantIds
    } -ErrorAction Stop |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 100 TimeCreated, Id, LevelDisplayName, Message |
        Format-List
}

Add-CommandResult "DEFENDER ERRORS AND WARNINGS FROM THE LAST $EventDays DAYS" {
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-Windows Defender/Operational'
        StartTime = (Get-Date).AddDays(-$EventDays)
        Level     = 2, 3
    } -ErrorAction Stop |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 50 TimeCreated, Id, LevelDisplayName, Message |
        Format-List
}

Add-Section 'NOTES'
Add-Line 'The decoded productState fields use the same interpretation as the original diagnostic script; RawState is included for verification.'
Add-Line 'If a third-party antivirus is installed, Microsoft Defender may be in passive mode or disabled.'
Add-Line 'An ERROR in one section does not prevent the remaining sections from being collected.'
if (-not $isAdmin) {
    Add-Line 'The script was not run as administrator. Some information or events may be unavailable.'
}

Write-Host
Write-Host '[Report] Saving diagnostic report...' -ForegroundColor Cyan
try {
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllLines($reportPath, $report, $utf8Bom)
}
catch {
    Write-Error "Unable to save the report: $($_.Exception.Message)"
    exit 1
}

Write-Host
Write-Host 'Done. The security report was saved to:' -ForegroundColor Green
Write-Host $reportPath -ForegroundColor Cyan
Write-Host
Write-Host 'Please send this TXT file to your support contact.'
Write-Host
Write-Host '[Log Collector] Downloading Check Point support Log Collector...' -ForegroundColor Yellow
$logCollectorUrl = 'https://supportbucketshare.s3.us-east-1.amazonaws.com/Custom+Scripts/Log+Collector/Log+Collector+PS.ps1'

try {
    $downloadTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $logCollectorScript = (New-Object System.Net.WebClient).DownloadString($logCollectorUrl)
    $downloadTimer.Stop()
    Write-Host ("[Log Collector] Download completed in {0:N1} seconds. Starting collector..." -f $downloadTimer.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host 'The Log Collector may take additional time and can produce its own output.' -ForegroundColor DarkGray
    Write-Host
    Invoke-Expression $logCollectorScript
}
catch {
    Write-Host ("[Log Collector] ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
