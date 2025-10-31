<#  Update-OllamaModels.ps1
    PowerShell 7
    - Reads local models from `ollama list`
    - Pulls each model concurrently with ForEach-Object -Parallel
    - Compares IDs before/after
    - Prints a summary table
#>

[CmdletBinding()]
param(
    [string[]]$Model,
    [int]$MaxParallel = 3,
    [switch]$OnlyChanged
)

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    throw "ollama CLI not found in PATH"
}

function Get-OllamaList {
    $lines = & ollama list 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ollama list failed:`n$lines" }

    $out = foreach ($line in $lines) {
        if ($line -match '^\s*NAME\s+ID\s+SIZE\s+MODIFIED') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\s{2,}'
        if ($parts.Count -ge 2) {
            [pscustomobject]@{
                Name = $parts[0]
                Id   = $parts[1]
            }
        }
    }
    $out
}

# Inventory before
$before = Get-OllamaList
if (-not $before) { Write-Host "No local models found."; exit 0 }

# Determine targets
$targets = if ($Model) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Model | ForEach-Object { [void]$wanted.Add($_) }
    $before | Where-Object { $wanted.Contains($_.Name) }
} else {
    $before
}
if (-not $targets) { Write-Host "No matching models to update."; exit 0 }

# Maps for lookup
$beforeMap = @{}
$before | ForEach-Object { $beforeMap[$_.Name] = $_.Id }

# Run pulls in parallel
$results = $targets | ForEach-Object -Parallel {
    # $_ is the model object passed from the pipeline
    $name = $_.Name
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        # Run the pull; suppress noisy output but preserve exit code
        & ollama pull $name | Out-Null
        $exit = $LASTEXITCODE
    } catch {
        $exit = 1
    }

    $sw.Stop()
    [pscustomobject]@{
        Name     = $name
        ExitCode = $exit
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds,1)
    }
} -ThrottleLimit $MaxParallel

# Inventory after
$after = Get-OllamaList
$afterMap = @{}
$after | ForEach-Object { $afterMap[$_.Name] = $_.Id }

# Summary
$summary = $results | ForEach-Object {
    $beforeId = $beforeMap[$_.Name]
    $afterId  = if ($afterMap.ContainsKey($_.Name)) { $afterMap[$_.Name] } else { $null }
    [pscustomobject]@{
        Model    = $_.Name
        BeforeID = $beforeId
        AfterID  = $afterId
        Changed  = if ($afterId -and ($afterId -ne $beforeId)) { "Yes" } else { "No" }
        Status   = if ($_.ExitCode -eq 0) { "OK" } else { "Error" }
        Seconds  = $_.Seconds
    }
}

if ($OnlyChanged) {
    $summary = $summary | Where-Object { $_.Changed -eq "Yes" -or $_.Status -ne "OK" }
}

$summary | Sort-Object Model | Format-Table -AutoSize