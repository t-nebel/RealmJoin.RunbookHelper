# Module manifest for module 'RealmJoin.RunbookHelper'

@{
    RootModule        = 'RealmJoin.RunbookHelper.psm1'
    ModuleVersion     = '0.8.5'
    GUID              = '50c59179-6cb8-4968-bf76-e7de04f02957'
    Author            = 'glueckkanja AG'
    CompanyName       = 'glueckkanja AG'
    Copyright         = '(c) glueckkanja AG. All rights reserved.'
    Description       = 'Helps to integrate Azure Automation scripts with RealmJoin.'
    PowerShellVersion = '5.1'
    # RequiredModules = @()

    # should specify all three of the following to speed up command auto-discovery
    FunctionsToExport = @(
        'Use-RjRbInterface', 'Write-RjRbLog', 'Write-RjRbDebug',
        'Invoke-RjRbRestMethod', 'Invoke-RjRbRestMethodGraph', 'Invoke-RjRbRestMethodDefenderATP',
        'Connect-RjRbAzAccount', 'Connect-RjRbAzureAD', 'Get-RjRbAzureADTenantDetail', 'Connect-RjRbExchangeOnline',
        'Connect-RjRbGraph', 'Connect-RjRbDefenderATP', 'Send-RjReportEmail'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @('Use-RJInterface')

    PrivateData       = @{
        PSData = @{
            ProjectUri = 'https://github.com/realmjoin/RealmJoin.RunbookHelper'
            # Prerelease = 'rc1'
        }
    }
}

