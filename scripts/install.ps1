[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = ".",

    [string[]]$Stacks = @(),

    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}
$targetRoot = (Resolve-Path -LiteralPath $Target).Path

if ([string]::Equals($sourceRoot, $targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Target must be a project directory outside the AI Kit source."
}

$allowed = @("php", "laravel", "moodle", "go")
$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($Stacks.Count -eq 0) {
    foreach ($stack in $allowed) { [void]$selected.Add($stack) }
} else {
    foreach ($item in $Stacks) {
        foreach ($stack in ($item -split ',')) {
            $name = $stack.Trim().ToLowerInvariant()
            if ($name -notin $allowed) { throw "Unknown stack '$name'. Allowed: $($allowed -join ', ')." }
            [void]$selected.Add($name)
        }
    }
}
if ($selected.Contains("laravel") -or $selected.Contains("moodle")) {
    [void]$selected.Add("php")
}

$files = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($name in @("AGENTS.md", "CLAUDE.md", "AI_CONTEXT.md", "KIMI.md", "MANUS.md", "GEMINI.md", ".windsurfrules")) {
    $files.Add((Get-Item -LiteralPath (Join-Path $sourceRoot $name)))
}
foreach ($folder in @(".ai", ".cursor")) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot $folder) -File -Recurse) {
        $files.Add($file)
    }
}
$files.Add((Get-Item -LiteralPath (Join-Path $sourceRoot ".github/copilot-instructions.md")))

$copy = [Collections.Generic.List[object]]::new()
$conflicts = [Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    if ($relative -match '^\.ai[\\/]stacks[\\/]([^\\/]+)\.md$') {
        if (-not $selected.Contains($Matches[1])) { continue }
    }
    $destination = Join-Path $targetRoot $relative
    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        $same = (Get-FileHash -LiteralPath $file.FullName).Hash -eq (Get-FileHash -LiteralPath $destination).Hash
        if (-not $same) { $conflicts.Add($relative) }
    }
    $copy.Add([pscustomobject]@{ Source = $file.FullName; Destination = $destination; Relative = $relative })
}

if ($conflicts.Count -gt 0) {
    throw "Refusing to overwrite existing files:`n - $($conflicts -join "`n - ")`nRe-run with -Force after reviewing them."
}

foreach ($item in $copy) {
    $parent = Split-Path -Parent $item.Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($Force -or -not (Test-Path -LiteralPath $item.Destination)) {
        Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force:$Force
    }
}

Write-Host "AI Kit installed in $targetRoot"
Write-Host "Active stack profiles: $((@($selected) | Sort-Object) -join ', ')"
Write-Host "Next: fill .ai/project/repo-map.md and copy the required templates from .ai/templates/github/."

