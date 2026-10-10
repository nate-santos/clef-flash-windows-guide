<#
.SYNOPSIS
    Decides over an image + text state with a clef decision model via Ollama.

.DESCRIPTION
    clef-flash is multimodal through Ollama's /v1/systemone endpoint: images
    are base64-encoded into the `images` field and scored jointly with the
    text state. Requires Ollama v0.40.1+ on Windows (earlier releases hit the
    non-finite-logit bug — see the guide's Gotchas).

    Example — one yes/no question over a screenshot:
      .\decide-image.ps1 -Image .\screenshot.png `
        -State "A user took this screenshot and wants to know what it shows." `
        -Questions '{"has_vscode":{"type":"noul","instructions":"Does this image show VS Code?"}}'

    Questions can live in a JSON file instead — pass the file path:
      .\decide-image.ps1 -Image .\receipt.jpg -State "Expense report" `
        -Questions .\questions.json

    Multiple images are shared by all questions, in order:
      .\decide-image.ps1 -Image .\a.png,.\b.png -State "..." -Questions '{...}'

    Question shapes (same as the guide):
      noul:   {"type":"noul","instructions":"..."}
      choice: {"type":"choice","instructions":"...","criteria":{"a":"Desc A","b":"Desc B"}}
      score:  {"type":"score","instructions":"...","criteria":["Low","Medium","High"]}

.PARAMETER Image
    Path(s) to PNG, JPEG, or WebP image file(s). URLs and data URLs are not
    accepted by the endpoint — it must be local files.

.PARAMETER State
    The text state to judge alongside the image(s). Required by the endpoint
    even when the decision is mostly about the picture.

.PARAMETER Questions
    1-64 named questions as a JSON string, or a path to a .json file
    containing the questions object.

.PARAMETER ServerUrl
    Base URL of Ollama. Default http://localhost:11434

.PARAMETER Model
    Model name as Ollama knows it. Default "clef-flash".
#>
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Image,

    [Parameter(Mandatory = $true)]
    [string]$State,

    [Parameter(Mandatory = $true)]
    [string]$Questions,

    [string]$ServerUrl = "http://localhost:11434",
    [string]$Model = "clef-flash"
)

$ErrorActionPreference = "Stop"

# --- encode images ---
$imagesB64 = @()
foreach ($p in $Image) {
    if (-not (Test-Path $p)) { throw "Image not found: $p" }
    $ext = [IO.Path]::GetExtension($p).ToLowerInvariant()
    if ($ext -notin @(".png", ".jpg", ".jpeg", ".webp")) {
        Write-Warning "Unexpected extension '$ext' on $p — endpoint accepts PNG, JPEG, WebP."
    }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $p).Path)
    $imagesB64 += [Convert]::ToBase64String($bytes)
    Write-Host ("  encoded {0} ({1:N1} KB)" -f $p, ($bytes.Length / 1KB))
}

# --- questions: JSON string or path to a JSON file ---
$qText = $Questions
if (Test-Path $Questions) { $qText = Get-Content -Raw $Questions }
try {
    $qObj = $qText | ConvertFrom-Json
} catch {
    throw "Could not parse -Questions as JSON (or JSON file): $_"
}

$body = @{
    model     = $Model
    state     = $State
    images    = $imagesB64
    questions = $qObj
} | ConvertTo-Json -Depth 10 -Compress

# --- send ---
try {
    $r = Invoke-RestMethod -Uri "$ServerUrl/v1/systemone" -Method Post `
        -ContentType "application/json" -Body $body -TimeoutSec 300
} catch {
    throw "Request failed: $($_.Exception.Message)"
}

# --- print answers ---
Write-Host ""
foreach ($prop in $r.answers.PSObject.Properties) {
    $a = $prop.Value
    Write-Host ("[{0}] ({1})" -f $prop.Name, $a.type)
    switch ($a.type) {
        "noul" {
            Write-Host ("  true: {0:P1}" -f $a.noul)
        }
        "choice" {
            Write-Host ("  choice: {0} (confidence {1:P0})" -f $a.choice, $a.confidence)
            foreach ($o in $a.probabilities.PSObject.Properties) {
                Write-Host ("    {0,-12} {1:P1}" -f $o.Name, $o.Value)
            }
        }
        "score" {
            Write-Host ("  score: {0:N2} (confidence {1:P0})" -f $a.score, $a.confidence)
            if ($a.legend) { Write-Host ("  legend: {0}" -f ($a.legend -join " / ")) }
        }
        default { Write-Host ($a | ConvertTo-Json -Compress) }
    }
}
if ($r.usage) {
    Write-Host ("`ninput_tokens: {0}, output_tokens: {1}" -f $r.usage.input_tokens, $r.usage.output_tokens)
}
