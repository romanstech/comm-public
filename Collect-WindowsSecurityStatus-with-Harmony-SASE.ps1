#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateRange(1, 365)]
    [int]$EventDays = 14
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# This collector requires elevation. Fail early with a clear message instead of
# allowing individual security/network collection commands to fail later.
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch {
    $isAdmin = $false
}

if (-not $isAdmin) {
    Write-Host
    Write-Host 'ERROR: Administrator privileges are required.' -ForegroundColor Red
    Write-Host 'Please open PowerShell using "Run as administrator" and run this command again.' -ForegroundColor Yellow
    Write-Host
    exit 1
}

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
    Write-Host ("[Log Collector] Download completed in {0:N1} seconds." -f $downloadTimer.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host '[Log Collector] Automatic answers enabled: Extended logs = N, Data Residency = EU (2).' -ForegroundColor Cyan

    # Check Point Log Collector v11 has an unhandled exception in Test-Port:
    # TcpClient.ConnectAsync(...).Wait(250) throws when DNS resolution or the TCP
    # connection fails. Replace the complete Test-Port function by boundaries rather
    # than exact text, so CRLF/whitespace/vendor formatting changes do not break the patch.
    $newTestPort = @'
function Test-Port {
    param(
        $RemoteHost,
        $Port
    )

    $TCPClient = $null
    try {
        $TCPClient = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $TCPClient.ConnectAsync($RemoteHost, $Port)

        try {
            $completed = $connectTask.Wait(250)
        }
        catch {
            $reason = $_.Exception.Message
            if ($_.Exception.InnerException) {
                $reason = $_.Exception.InnerException.Message
            }
            return "TCP Port check for $RemoteHost on port $Port failed! Reason: $reason"
        }

        if ($completed -and $TCPClient.Connected) {
            return "TCP Port check for $RemoteHost on port $Port was a success!"
        }

        return "TCP Port check for $RemoteHost on port $Port failed!"
    }
    catch {
        $reason = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $reason = $_.Exception.InnerException.Message
        }
        return "TCP Port check for $RemoteHost on port $Port failed! Reason: $reason"
    }
    finally {
        if ($null -ne $TCPClient) {
            $TCPClient.Dispose()
        }
    }
}

'@

    $testPortStart = $logCollectorScript.IndexOf('function Test-Port {', [System.StringComparison]::Ordinal)
    $testPortEndMarker = '#Get Certificate information'
    $testPortEnd = $logCollectorScript.IndexOf($testPortEndMarker, $testPortStart, [System.StringComparison]::Ordinal)

    if ($testPortStart -ge 0 -and $testPortEnd -gt $testPortStart) {
        $beforeTestPort = $logCollectorScript.Substring(0, $testPortStart)
        $afterTestPort = $logCollectorScript.Substring($testPortEnd)
        $logCollectorScript = $beforeTestPort + $newTestPort + $afterTestPort

        Write-Host '[Log Collector] Applied compatibility fix for Check Point v11 Test-Port DNS/TCP exception.' -ForegroundColor Green

        # Verify that the dangerous vendor Wait() call was actually removed before execution.
        if ($logCollectorScript -match '\$TCPClient\.ConnectAsync\(\$RemoteHost,\s*\$Port\)\.Wait\(250\)') {
            throw 'Compatibility patch verification failed: original Test-Port Wait(250) call is still present.'
        }
        Write-Host '[Log Collector] Patch verification passed.' -ForegroundColor Green
    }
    else {
        throw 'Unable to locate the Test-Port function boundaries in the downloaded Check Point collector. Vendor script was not executed.'
    }

    Write-Host '[Log Collector] Starting collector...' -ForegroundColor Yellow
    Write-Host

    # The Check Point collector currently asks two Read-Host questions before collection.
    # Shadow Read-Host only while the vendor script runs. The first two answers are
    # supplied automatically; any later/unexpected prompt falls back to normal Read-Host.
    $collectorAnswers = New-Object 'System.Collections.Generic.Queue[string]'
    $collectorAnswers.Enqueue('n')
    $collectorAnswers.Enqueue('2')

    function Read-Host {
        param([Parameter(Position = 0)][string]$Prompt)

        if ($script:collectorAnswers -and $script:collectorAnswers.Count -gt 0) {
            $answer = $script:collectorAnswers.Dequeue()
            if ([string]::IsNullOrWhiteSpace($Prompt)) {
                Write-Host $answer
            }
            else {
                Write-Host ("{0}: {1}" -f $Prompt, $answer)
            }
            return $answer
        }

        Microsoft.PowerShell.Utility\Read-Host @PSBoundParameters
    }

    try {
        Invoke-Expression $logCollectorScript
    }
    finally {
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
        Remove-Variable collectorAnswers -Scope Script -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Host
    Write-Host ("[Log Collector] ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red

    # Show useful source/stack information for errors thrown inside the downloaded
    # Check Point collector. This is especially useful for the v11 async Wait/DNS issue.
    if ($_.InvocationInfo) {
        if ($_.InvocationInfo.ScriptLineNumber) {
            Write-Host ("[Log Collector] Script line: {0}" -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkYellow
        }
        if ($_.InvocationInfo.PositionMessage) {
            Write-Host '[Log Collector] Position:' -ForegroundColor DarkYellow
            Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
        }
    }
    if ($_.ScriptStackTrace) {
        Write-Host '[Log Collector] Stack trace:' -ForegroundColor DarkYellow
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }

    if ($_.Exception.Message -match 'Wait|requested name|name.*valid|data.*type') {
        Write-Host
        Write-Host '[Log Collector] The failure looks like a DNS-resolution exception inside the Check Point collector.' -ForegroundColor Yellow
        Write-Host '[Log Collector] Testing the main EU Harmony SASE DNS names...' -ForegroundColor Yellow

        $euHosts = @(
            'eu.sase.checkpoint.com',
            'api.eu.sase.checkpoint.com',
            'auth.eu.sase.checkpoint.com',
            'sdp.eu.sase.checkpoint.com',
            'yarkon.eu.sase.checkpoint.com'
        )

        foreach ($hostName in $euHosts) {
            try {
                if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
                    $records = Resolve-DnsName -Name $hostName -Type A -DnsOnly -ErrorAction Stop |
                        Where-Object { $_.IPAddress } |
                        Select-Object -ExpandProperty IPAddress
                }
                else {
                    $records = [System.Net.Dns]::GetHostAddresses($hostName) |
                        ForEach-Object { $_.IPAddressToString }
                }

                if ($records) {
                    Write-Host ("  OK   {0} -> {1}" -f $hostName, ($records -join ', ')) -ForegroundColor Green
                }
                else {
                    Write-Host ("  WARN {0} -> no A records returned" -f $hostName) -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host ("  FAIL {0} -> {1}" -f $hostName, $_.Exception.Message) -ForegroundColor Red
            }
        }

        # Print Wait() locations from the exact downloaded vendor script so the failing
        # statement can be patched safely if this is a Check Point script defect.
        if ($logCollectorScript) {
            $vendorLines = $logCollectorScript -split "`r?`n"
            $waitMatches = for ($i = 0; $i -lt $vendorLines.Count; $i++) {
                if ($vendorLines[$i] -match '\.Wait\s*\(') {
                    [PSCustomObject]@{ Line = $i + 1; Text = $vendorLines[$i].Trim() }
                }
            }
            if ($waitMatches) {
                Write-Host
                Write-Host '[Log Collector] Wait() calls found in downloaded Check Point script:' -ForegroundColor DarkYellow
                $waitMatches | ForEach-Object {
                    Write-Host ("  Line {0}: {1}" -f $_.Line, $_.Text) -ForegroundColor DarkGray
                }
            }
        }
    }
}
