Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-CollectorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO','OK','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'INFO' { 'Cyan' }
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
    }

    Write-Host ("[{0}] [{1}] {2}" -f $stamp, $Level, $Message) -ForegroundColor $color
}

function Test-AzCliPrerequisites {
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw 'Azure CLI (az) was not found in PATH. Install Azure CLI and run az login first.'
    }
}

function ConvertTo-CollectorSafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return ($Text -replace '[^A-Za-z0-9._-]', '-')
}

function Invoke-AzCommandJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string]$Subscription,

        [switch]$Required
    )

    $fullArgs = [System.Collections.Generic.List[string]]::new()
    $fullArgs.AddRange($Arguments)

    if ($Subscription) {
        $fullArgs.Add('--subscription')
        $fullArgs.Add($Subscription)
    }

    $fullArgs.Add('--output')
    $fullArgs.Add('json')
    $fullArgs.Add('--only-show-errors')

    $quoted = foreach ($a in $fullArgs) {
        if ($a -match '\s') { '"{0}"' -f $a.Replace('"','\"') } else { $a }
    }

    $commandText = 'az {0}' -f ($quoted -join ' ')
    Write-CollectorMessage -Level 'INFO' -Message ("Collecting {0}" -f $Label)

    $raw = & az @fullArgs 2>&1
    $exit = $LASTEXITCODE

    $rawText = (($raw | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
    }) -join [Environment]::NewLine).Trim()

    $data = $null
    if ($rawText) {
        try {
            $data = $rawText | ConvertFrom-Json -Depth 100
        }
        catch {
            $data = $rawText
        }
    }

    $success = $exit -eq 0
    if ($Required -and -not $success) {
        throw ("Required command failed for '{0}': {1}" -f $Label, $rawText)
    }

    if ($success) {
        Write-CollectorMessage -Level 'OK' -Message ("Collected {0}" -f $Label)
    }
    else {
        Write-CollectorMessage -Level 'WARN' -Message ("Could not collect {0}" -f $Label)
    }

    return [pscustomobject]@{
        label = $Label
        command = $commandText
        success = $success
        exitCode = $exit
        error = if ($success) { $null } else { $rawText }
        data = $data
    }
}

function Test-SensitiveName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '(?i)(password|passwd|pwd|secret|token|connectionstring|accountkey|sharedaccesskey|sharedkey|clientsecret|sas|instrumentationkey)'
}

function Test-SensitiveValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value -match '(?i)(password\s*=|pwd\s*=|accountkey\s*=|sharedaccesssignature=|sig=|clientsecret\s*=|://.+:.+@)'
}

function Protect-CollectorObject {
    param(
        $InputObject,
        [string]$PropertyName = ''
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string]) {
        if ((Test-SensitiveName -Name $PropertyName) -or (Test-SensitiveValue -Value $InputObject)) {
            return 'SECRET_FOUND_REDACTED'
        }
        return $InputObject
    }

    if ($InputObject -is [ValueType]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $copy[$key] = Protect-CollectorObject -InputObject $InputObject[$key] -PropertyName ([string]$key)
        }
        return [pscustomobject]$copy
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = foreach ($item in $InputObject) {
            Protect-CollectorObject -InputObject $item -PropertyName $PropertyName
        }
        return @($items)
    }

    $props = @($InputObject.PSObject.Properties)
    if ($props.Length -eq 0) { return $InputObject }

    $copy = [ordered]@{}
    foreach ($prop in $props) {
        $copy[$prop.Name] = Protect-CollectorObject -InputObject $prop.Value -PropertyName $prop.Name
    }

    return [pscustomobject]$copy
}

function New-CollectorDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceType,

        [Parameter(Mandatory = $true)]
        [string]$ResourceName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,

        [string]$Subscription
    )

    return [ordered]@{
        metadata = [ordered]@{
            schemaVersion = '1.0'
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            resourceType = $ResourceType
            resourceName = $ResourceName
            resourceGroup = $ResourceGroup
            subscription = $Subscription
        }
        sections = [ordered]@{}
    }
}

function Add-CollectorSection {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Document,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $Document.sections[$Name] = [ordered]@{
        success = $Result.success
        command = $Result.command
        exitCode = $Result.exitCode
        error = $Result.error
        data = Protect-CollectorObject -InputObject $Result.data
    }
}

function Save-CollectorDocument {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Document,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $folder = Split-Path -Parent $OutputPath
    if (-not (Test-Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    ($Document | ConvertTo-Json -Depth 100) | Set-Content -Path $OutputPath -Encoding utf8
}
