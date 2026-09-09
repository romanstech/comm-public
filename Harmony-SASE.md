## Install [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6#winget):
```
winget install --id Microsoft.PowerShell --source winget
```
## Run Harmony SASE diagnostic tool:
Open **PowerShell** as **Administrator** and run the command:
```
iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/romanstech/comm-public/main/Collect-WindowsSecurityStatus-with-Harmony-SASE.ps1'))
```
Send 2 resulting files from **C:\Users\Public\Harmony SASE Log** folder to the support
```
Windows-Security-Report-xxx
hsase_info_xxx
```
