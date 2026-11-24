#Requires -RunAsAdministrator
<#
.SYNOPSIS
Refreshes Windows audio endpoints after Bluetooth audio is already connected.
.DESCRIPTION
Manual recovery only. All local audio streams are briefly interrupted. Does not install drivers or change pairing.
See docs/REPAIRS.zh-CN.md for the tested scope and unresolved reconnect issue.
#>
$ErrorActionPreference = 'Stop'
Write-Output 'Bluetooth audio must already be connected. Refreshing Windows audio endpoints; audio will briefly stop.'
try {
    Stop-Service -Name Audiosrv -Force -ErrorAction Stop
    Restart-Service -Name AudioEndpointBuilder -Force -ErrorAction Stop
} finally {
    Start-Service -Name Audiosrv -ErrorAction Stop
}
Get-Service -Name AudioEndpointBuilder, Audiosrv | Select-Object Name, Status
