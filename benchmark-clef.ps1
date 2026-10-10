<#
.SYNOPSIS
    Benchmarks clef-flash decision latency on a local llama-server.

.DESCRIPTION
    Sends 10 representative decision states to the /v1/systemone endpoint,
    times each request client-side, and reports per-state and overall median
    latency. A decision request is one forward pass (no token-by-token
    generation), so seconds-per-decision is the metric that matters here.

    Use the same 10 states (this script, unchanged) against each of the
    guide's three builds to make Path A / B / C comparable:
      A: prebuilt Vulkan        .\benchmark-clef.ps1
      B: prebuilt SYCL          .\benchmark-clef.ps1
      C: SYCL from source       .\benchmark-clef.ps1
    Stop the previous build's server before starting the next one.

.PARAMETER ServerUrl
    Base URL of the llama-server, e.g. http://localhost:8080

.PARAMETER Model
    Model name as the server knows it. Default matches the guide's -hf route.

.PARAMETER Repeats
    How many timed runs per state. Default 3. The first request is a warmup
    and is never counted.

.PARAMETER OutCsv
    Path to write per-request results. Default: bench-results.csv next to this script.
#>
param(
    [string]$ServerUrl = "http://localhost:8080",
    [string]$Model = "clef-flash",
    [int]$Repeats = 3,
    [string]$OutCsv = (Join-Path $PSScriptRoot "bench-results.csv")
)

$ErrorActionPreference = "Stop"

$questions = @{
    triage = @{
        page = @{ type = "noul"; instructions = "Should someone be paged right now?" }
        sev  = @{ type = "score"; instructions = "How severe is this?"; criteria = @("Info", "Minor", "Major", "Critical") }
    }
    route = @{
        team = @{ type = "choice"; instructions = "Which team should handle this?";
                  criteria = @{ billing = $null; technical = $null; sales = $null } }
        urgent = @{ type = "noul"; instructions = "Is this request urgent?" }
    }
    risk = @{
        block = @{ type = "noul"; instructions = "Should this change be blocked?" }
        risk  = @{ type = "score"; instructions = "Risk level?"; criteria = @("Low", "Medium", "High") }
    }
}

# 10 states: short, medium, and long-ish, sized from ~20 words up to ~400 words
# (a few hundred tokens to ~2k tokens — the guide's estimate range).
$states = @(
    @{ name = "db-disk";      qs = $questions.triage;
       text = "Disk on db-02 is at 97% and growing about 1% an hour." },
    @{ name = "login-spike";  qs = $questions.route;
       text = "Login failures for the web app tripled in the last 10 minutes; all from one /24 in the same region as yesterday's credential-stuffing wave." },
    @{ name = "refund-req";   qs = $questions.route;
       text = "Customer asks for a refund on a renewal billed 3 days ago. They say they cancelled through the app last month but the cancellation never took effect." },
    @{ name = "deploy";       qs = $questions.risk;
       text = "Deploy v2.14.3 to production: changelog mentions a schema migration on the sessions table, a dependency bump for the image library with a CVE fix, and a feature flag flip for the new checkout flow. Canary passed on 5% traffic for 2 hours with no error-rate change." },
    @{ name = "support-rant"; qs = $questions.route;
       text = "Ticket: 'Checkout has been failing for every customer for the last hour. We are losing real money. This happened during your maintenance window. Escalate this to someone who can actually fix it.' Agent note: no maintenance was scheduled; error logs show payment provider timeouts, not our code." },
    @{ name = "access-req";   qs = $questions.route;
       text = "Contractor starting Monday requests read access to the analytics warehouse and write access to the staging schema. Their manager approved read but staging write is still pending approval. Policy says contractors get least privilege until both approvals are on file." },
    @{ name = "latency";      qs = $questions.triage;
       text = "p99 latency on the search endpoint rose from 180ms to 900ms over the last 30 minutes. Traffic is flat. The slow trace points at a new full-table scan introduced in yesterday's index change; the on-call already reverted it on the replica but the primary still serves the old plan." },
    @{ name = "data-export";  qs = $questions.risk;
       text = "Marketing wants a CSV export of all users who opened an email in the last 90 days, including email address and last purchase date, to upload to an ad platform for lookalike targeting. The privacy policy promises we do not share personal data with ad networks without explicit opt-in; there is no record of which of these users opted in." },
    @{ name = "cert-renew";   qs = $questions.triage;
       text = "The TLS certificate for the API gateway expires in 36 hours. Renewal was requested but the DNS validation record has not propagated, and the on-call who owns the DNS zone is on vacation until Monday. The last renewal attempt failed for the same reason and was retried manually." },
    @{ name = "vendor-quote"; qs = $questions.risk;
       text = "Vendor quote for the log pipeline: Option 1 is a managed service at $1,900/month with a 12-month commit and data residency in the EU. Option 2 is self-hosted on our cluster, estimated $600/month in compute but roughly 2 weeks of eng time to set up and ongoing maintenance. Option 3 renews the current provider at $2,400/month, month-to-month, with known reliability problems. Finance prefers option 1, eng prefers option 2." }
)

function Invoke-Decision {
    param([string]$StateText, [hashtable]$Questions)
    $body = @{
        model     = $Model
        state     = $StateText
        questions = $Questions
    } | ConvertTo-Json -Depth 10 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$ServerUrl/v1/systemone" -Method Post `
            -ContentType "application/json" -Body $body -TimeoutSec 300
        $sw.Stop()
        return @{ ms = [int]$sw.ElapsedMilliseconds; ok = $true; answers = ($r.answers | ConvertTo-Json -Compress) }
    } catch {
        $sw.Stop()
        return @{ ms = [int]$sw.ElapsedMilliseconds; ok = $false; answers = $_.Exception.Message }
    }
}

# --- warmup (discarded) ---
Write-Host "Warming up..."
$null = Invoke-Decision -StateText $states[0].text -Questions $states[0].qs

$results = @()
foreach ($s in $states) {
    $lat = @()
    for ($i = 1; $i -le $Repeats; $i++) {
        $r = Invoke-Decision -StateText $s.text -Questions $s.qs
        $lat += $r.ms
        $results += [pscustomobject]@{ state = $s.name; run = $i; latency_ms = $r.ms; ok = $r.ok }
        Write-Host ("  {0} run {1}/{2}: {3} ms ({4})" -f $s.name, $i, $Repeats, $r.ms, $(if ($r.ok) { "ok" } else { "ERROR" }))
    }
    $sorted = $lat | Sort-Object
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    Write-Host ("  -> {0} median: {1} ms" -f $s.name, $median)
}

$results | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8

$all = ($results | Where-Object { $_.ok } | Select-Object -ExpandProperty latency_ms | Sort-Object)
$med = $all[[int][math]::Floor($all.Count / 2)]
$sec = [math]::Round($med / 1000, 2)
Write-Host ""
Write-Host ("Overall: {0} timed requests, median decision latency {1} ms ({2} s)" -f $all.Count, $med, $sec)
Write-Host "Saved per-request results to $OutCsv"
