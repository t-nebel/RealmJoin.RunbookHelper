# $VerbosePreference automatically is set to "Continue" by turning on "Log verbose records"
# But we only want to use the verbose stream for our own log output and not for verbose output from any other cmdlets
# that are getting called.
# Unfortunately setting this here does not always take effect (i.e. it does not seem to work in case our module is being
# loaded using Import-Module or by some Azure Automation heuristic before the runbook starts, so we also set it again
# inside the Connect-RjRb* CmdLets to avoid being spammed by e.g. the verbose loading log of the ExchangeOnline module.
$Global:VerbosePreference = "SilentlyContinue"

# Default should be to terminate on any errors when using our module
$Global:ErrorActionPreference = "Stop"
# We still want errors occuring inside this module to be terminating even if ErrorActionPreference is being changed again
# globally, so we also set this locally since then it will still take effect inside this module's functions
$ErrorActionPreference = "Stop"

# module scope only
Set-StrictMode -Version 3

# Workaround: Detect Azure Env. using Get-AutomationVariable
$Global:RjRbRunningInAzure = (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue) -or $env:AUTOMATION_ASSET_ACCOUNTID

. $PSScriptRoot\Logging.ps1

$logPrefix = "$([IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)):"
if ($RjRbRunningInAzure) {
    Write-RjRbLog "$logPrefix Running in Azure Automation account"
}
else {
    Write-RjRbLog "$logPrefix Not running in Azure - probably development environment"
    . $PSScriptRoot\DevCertificates.ps1
}

. $PSScriptRoot\Connection.ps1
. $PSScriptRoot\ConnectionAz.ps1
. $PSScriptRoot\ConnectionAzureAD.ps1
. $PSScriptRoot\ConnectionExchangeOnline.ps1
. $PSScriptRoot\ConnectionOAuth2.ps1
. $PSScriptRoot\Interface.ps1
. $PSScriptRoot\InternalHelpers.ps1
. $PSScriptRoot\Rest.ps1
. $PSScriptRoot\MailReport.ps1
