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
    [switch]$OnlyChanged,
    [switch]$ShowProgress
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
            $modified = if ($parts.Count -ge 4) { $parts[3] } else { $null }
            [pscustomobject]@{
                Name     = $parts[0]
                Id       = $parts[1]
                Modified = $modified
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

if ($ShowProgress) {
    # Run sequentially to keep progress output readable
    $results = foreach ($t in $targets) {
        $name = $t.Name
        $sw = [Diagnostics.Stopwatch]::StartNew()

        Write-Host "Updating $name..."
        try {
            # Show raw progress output from ollama
            & ollama pull $name
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
    }
} else {
    # Run pulls in parallel (quiet) to avoid noisy interleaved progress bars
    $results = $targets | ForEach-Object -Parallel {
        $name = $_.Name
        $sw = [Diagnostics.Stopwatch]::StartNew()

        try {
            & ollama pull $name > $null 2> $null
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
}

# Inventory after
$after = Get-OllamaList
$afterMap = @{}
$after | ForEach-Object { $afterMap[$_.Name] = $_.Id }
$afterModMap = @{}
$after | ForEach-Object { $afterModMap[$_.Name] = $_.Modified }

# Summary
$summary = $results | ForEach-Object {
    $beforeId = $beforeMap[$_.Name]
    $afterId  = if ($afterMap.ContainsKey($_.Name)) { $afterMap[$_.Name] } else { $null }
    [pscustomobject]@{
        Model    = $_.Name
        Updated  = if ($afterId -and ($afterId -ne $beforeId)) { "Yes" } else { "No" }
        Duration = if ($afterId -and ($afterId -ne $beforeId)) { $_.Seconds } else { $null }
        LastPull = if ($afterModMap.ContainsKey($_.Name)) { $afterModMap[$_.Name] } else { $null }
    }
}

if ($OnlyChanged) {
    $summary = $summary | Where-Object { $_.Updated -eq "Yes" }
}

# Final output: Model, Updated, Duration, LastPull
$summary | Sort-Object Model | Format-Table Model, Updated, @{Label='Duration';Expression={$_.Duration}}, @{Label='Last Pull';Expression={$_.LastPull}} -AutoSize