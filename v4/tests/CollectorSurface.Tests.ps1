$collectorDirectory = Split-Path $PSScriptRoot -Parent
$expectedCollectors = @(
    'Get-AppServicePlanData.ps1', 'Get-AppServiceData.ps1', 'Get-AppServiceSlotData.ps1',
    'Get-MySqlFlexibleServerData.ps1', 'Get-KeyVaultData.ps1', 'Get-ManagedRedisData.ps1',
    'Get-NatGatewayData.ps1', 'Get-FrontDoorData.ps1', 'Get-StorageAccountData.ps1',
    'Get-AzureCommunicationServicesData.ps1', 'Get-AppInsightsData.ps1',
    'Get-LogAnalyticsWorkspaceData.ps1', 'Get-NetworkTopologyData.ps1', 'Get-DefenderForCloudData.ps1'
)

Describe 'WordPress posture collector surface' {
    foreach ($collector in $expectedCollectors) {
        It "includes $collector" {
            Test-Path (Join-Path $collectorDirectory $collector) | Should Be $true
        }
    }
}