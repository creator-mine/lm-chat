# Registers lm-relay-agent.exe to start at user logon.
#
# LM Studio itself runs in the user session, so a per-user scheduled task is
# enough; no Windows service or administrator rights are required.
#
# Example:
#   .\install-agent.ps1 -AgentPath .\agent.exe `
#       -ConfigPath "$env:USERPROFILE\.config\lm-computer\relay-agent.json"

param(
    [Parameter(Mandatory = $true)]
    [string]$AgentPath,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$TaskName = "LM Relay Agent"
)

$ErrorActionPreference = "Stop"

$agent = (Resolve-Path -LiteralPath $AgentPath).Path
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$workdir = Split-Path -Parent $agent

$action = New-ScheduledTaskAction `
    -Execute $agent `
    -Argument "-config `"$config`"" `
    -WorkingDirectory $workdir

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "LM Chat relay agent for LM Studio" `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed scheduled task '$TaskName' and started the agent."
Write-Host "Check: Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
