$commonCollectorPath = Join-Path $PSScriptRoot '..\Common-AzureCollector.ps1'

Describe 'Common-AzureCollector module' {
    It 'exists so all v4 collectors share one safe JSON implementation' {
        Test-Path $commonCollectorPath | Should Be $true
    }
}