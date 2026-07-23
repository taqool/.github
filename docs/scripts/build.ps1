[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string[]]$Source,

  [string]$OutputDir = "build",

  [ValidateRange(1, 10)]
  [int]$Passes = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$SourceRoot = Join-Path $ProjectRoot "src"

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
  throw "Source directory not found: $SourceRoot"
}

if ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $OutputPath = [System.IO.Path]::GetFullPath($OutputDir)
}
else {
  $OutputPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $OutputDir))
}

$TempRoot = Join-Path $OutputPath ".latex"

function Resolve-TexSource {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RequestedSource
  )

  if ([System.IO.Path]::IsPathRooted($RequestedSource)) {
    $Candidates = @($RequestedSource)
  }
  else {
    $Candidates = @(
      (Join-Path $SourceRoot $RequestedSource),
      (Join-Path $ProjectRoot $RequestedSource)
    )
  }

  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
      $ResolvedSource = (Resolve-Path -LiteralPath $Candidate).Path
      if ([System.IO.Path]::GetExtension($ResolvedSource) -ne ".tex") {
        throw "Source must be a .tex file: $ResolvedSource"
      }

      return $ResolvedSource
    }
  }

  throw "Source file not found: $RequestedSource"
}

if ($Source -and $Source.Count -gt 0) {
  $SourcePaths = @(
    foreach ($RequestedSource in $Source) {
      Resolve-TexSource -RequestedSource $RequestedSource
    }
  )
}
else {
  $SourcePaths = @(
    Get-ChildItem -LiteralPath $SourceRoot -Filter "*.tex" -File |
      Sort-Object Name |
      ForEach-Object { $_.FullName }
  )
}

$SourcePaths = @($SourcePaths | Sort-Object -Unique)
if ($SourcePaths.Count -eq 0) {
  throw "No .tex files found in $SourceRoot"
}

$XeLatex = Get-Command "xelatex" -CommandType Application -ErrorAction SilentlyContinue
if (-not $XeLatex) {
  throw "xelatex was not found in PATH. Install MiKTeX or TeX Live with XeLaTeX support."
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

if (Test-Path -LiteralPath $TempRoot) {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

$BuildSucceeded = $false

Push-Location $ProjectRoot
try {
  foreach ($SourcePath in $SourcePaths) {
    $JobName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $JobTempPath = Join-Path $TempRoot $JobName
    $LogPath = Join-Path $JobTempPath "$JobName.log"

    New-Item -ItemType Directory -Force -Path $JobTempPath | Out-Null

    for ($Pass = 1; $Pass -le $Passes; $Pass++) {
      Write-Host "[$JobName] XeLaTeX pass $Pass of $Passes"

      & $XeLatex.Source `
        -interaction=nonstopmode `
        -halt-on-error `
        -file-line-error `
        -synctex=0 `
        "-output-directory=$JobTempPath" `
        $SourcePath

      if ($LASTEXITCODE -ne 0) {
        throw "XeLaTeX failed on pass $Pass for $SourcePath. See $LogPath"
      }
    }

    $BuiltPdf = Join-Path $JobTempPath "$JobName.pdf"
    if (-not (Test-Path -LiteralPath $BuiltPdf -PathType Leaf)) {
      throw "Expected PDF was not produced: $BuiltPdf"
    }

    $DestinationPdf = Join-Path $OutputPath "$JobName.pdf"
    Copy-Item -LiteralPath $BuiltPdf -Destination $DestinationPdf -Force
    Write-Host "Built $DestinationPdf"
  }

  $BuildSucceeded = $true
}
finally {
  Pop-Location

  if ($BuildSucceeded -and (Test-Path -LiteralPath $TempRoot)) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
  }
}

Write-Host "Completed $($SourcePaths.Count) PDF build(s) with XeLaTeX."
