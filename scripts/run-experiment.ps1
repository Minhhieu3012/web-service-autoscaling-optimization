# scripts/run-experiment.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('baseline-cpu','custom-unoptimized','custom-optimized')][string]$Policy,
    [Parameter(Mandatory=$true)][ValidateSet('step','spike','periodic','fault')][string]$Scenario,
    [ValidateSet('cpu','queue')][string]$Endpoint='queue',
    [int]$Repeat=1,
    [string]$BaseUrl='http://127.0.0.1:8000',
    [string]$PrometheusUrl='http://127.0.0.1:9090',
    [int]$Rate=10,
    [int]$MaxVus=150,
    [int]$Iterations=1000000,
    [double]$WorkTime=0.5,
    [int]$MaxQueueLimit=100,
    [int]$SampleSeconds=5
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($Repeat -lt 1 -or $Rate -lt 1 -or $MaxVus -lt 1 -or $SampleSeconds -lt 1) { throw 'Invalid positive integer parameter' }
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runId=('{0}-{1}-{2}-r{3:00}-{4}' -f $Policy,$Scenario,$Endpoint,$Repeat,(Get-Date -Format 'yyyyMMdd-HHmmss'))
$out=Join-Path $root ("data/$Policy/$runId")
New-Item -ItemType Directory -Force -Path $out | Out-Null
$k6=Get-Command k6 -ErrorAction Stop
$python=Get-Command python -ErrorAction Stop
$script=Join-Path $root ("load-tests/$Scenario-workload.js")
if ($Scenario -eq 'fault') { $script=Join-Path $root 'load-tests/fault-injection.js'; $Endpoint='queue'; $WorkTime=1.0; $MaxQueueLimit=10 }
if (!(Test-Path $script)) { throw "Missing k6 script: $script" }
$env:BASE_URL=$BaseUrl
$env:ENDPOINT=$Endpoint
$env:RATE=[string]$Rate
$env:MAX_VUS=[string]$MaxVus
$env:ITERATIONS=[string]$Iterations
$env:WORK_TIME=[string]$WorkTime
$env:MAX_QUEUE_LIMIT=[string]$MaxQueueLimit
$env:SUMMARY_FILE=(Join-Path $out 'k6-summary.json')
$begin=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$metadata=[ordered]@{
    policy=$Policy
    scenario=$Scenario
    endpoint=$Endpoint
    repeat=$Repeat
    rate=$Rate
    max_vus=$MaxVus
    iterations=$Iterations
    work_time=$WorkTime
    max_queue_limit=$MaxQueueLimit
    queue_limit=$MaxQueueLimit
    sample_seconds=$SampleSeconds
    base_url=$BaseUrl
    load_balanced=($BaseUrl -notmatch '^http://(127\.0\.0\.1|localhost):8000(/|$)')
    started_unix=$begin
    ended_unix=$null
    k6_exit_code=$null
    safety_stop=$null
    timestamp_precision='unix_seconds'
    note='Do not compare runs until policy/config and environment are confirmed'
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'metadata.json') -Encoding UTF8
Write-Host "Run folder: $out" -ForegroundColor Cyan
Write-Warning 'Make sure exactly one autoscaler is active, replica count is reset to 1, both port-forwards are active, and Prometheus is healthy.'
$exitCode=0
try {
    & $k6.Source run --out ("json="+(Join-Path $out 'k6-raw.json')) $script 2>&1 | Tee-Object -FilePath (Join-Path $out 'k6-console.log')
    $exitCode=$LASTEXITCODE
} finally {
    $end=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $metadata.ended_unix=$end
    $metadata.k6_exit_code=$exitCode
    $metadata | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'metadata.json') -Encoding UTF8
    & $python.Source (Join-Path $root 'scripts/collect-metrics.py') --prometheus-url $PrometheusUrl --start ($begin - 30) --end ($end + 30) --step $SampleSeconds --output $out
    Write-Host "Metrics collector exit code: $LASTEXITCODE"
}
if ($exitCode -ne 0) { Write-Warning "k6 exit code ${exitCode}: check thresholds and logs; measurements were retained" }
Write-Host "Data: $out" -ForegroundColor Green
