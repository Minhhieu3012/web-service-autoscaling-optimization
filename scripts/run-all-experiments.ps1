#Requires -Version 5.1
<#
.SYNOPSIS
    Safe local experiment orchestration for web-service-autoscaling-optimization.
.DESCRIPTION
    Preflight: no changes. Smoke: one HPA CPU run using local port-forward,
    not a multi-replica performance benchmark. Full: uses a temporary NodePort
    service and minikube service tunnel to exercise Kubernetes Service routing,
    runs matched workload/policy pairs, collects metrics and writes checkpoints.
    Fault test is opt-in and uses the safe supplemental k6 script.
#>
[CmdletBinding()]
param(
    [ValidateSet('Preflight','Smoke','Full')][string]$Mode = 'Preflight',
    [ValidateRange(1,5)][int]$Rate = 1,
    [ValidateRange(2,24)][int]$MaxVus = 6,
    [ValidateRange(1000,20000000)][int]$Iterations = 1000000,
    [ValidateRange(0.05,5)][double]$WorkTime = 0.5,
    [ValidateRange(5,100)][int]$MaxQueueLimit = 20,
    [ValidateRange(1,10)][int]$SampleSeconds = 5,
    [ValidateRange(75,95)][int]$MaxMinikubeMemoryPercent = 88,
    [ValidateRange(0.15,2)][double]$MinWindowsFreeGiB = 0.30,
    [switch]$IncludeFault,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runStarted = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $root ("data/automation-results/$runStarted")
$checkpointDir = Join-Path $root 'data/automation-checkpoints'
$ownedProcesses = New-Object System.Collections.ArrayList
$benchServiceOwned = $false
$runResults = New-Object System.Collections.ArrayList
$failureReason = $null
$baseUrl = $null
$promUrl = 'http://127.0.0.1:9090'

function Log([string]$msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }
function Require([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Tool([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($name -eq 'minikube') {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs/Minikube/minikube.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    throw "Missing executable: $name"
}
function KubectlJson([string[]]$arguments) {
    $output = & $script:kubectl @arguments -o json
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($arguments -join ' ')" }
    return ($output | Out-String | ConvertFrom-Json)
}
function Kube([string[]]$arguments) {
    & $script:kubectl @arguments
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($arguments -join ' ')" }
}
function UriHealthy([string]$uri) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 3
        return $r.StatusCode -eq 200
    } catch { return $false }
}
function CheckMemory {
    $os = Get-CimInstance Win32_OperatingSystem
    $freeGiB = [double]$os.FreePhysicalMemory / 1MB
    $raw = & $script:docker stats minikube --no-stream --format '{{json .}}'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Docker memory.' }
    $stat = $raw | ConvertFrom-Json
    $m = [regex]::Match([string]$stat.MemUsage, '^\s*([0-9.]+)\s*(KiB|MiB|GiB|B)\s*/\s*([0-9.]+)\s*(KiB|MiB|GiB|B)')
    if (-not $m.Success) { throw "Unexpected Docker memory format: $($stat.MemUsage)" }
    $factor = @{ B = 1; KiB = 1024; MiB = 1048576; GiB = 1073741824 }
    $used = [double]::Parse($m.Groups[1].Value, [cultureinfo]::InvariantCulture) * $factor[$m.Groups[2].Value]
    $limit = [double]::Parse($m.Groups[3].Value, [cultureinfo]::InvariantCulture) * $factor[$m.Groups[4].Value]
    $pct = 100 * $used / $limit
    Log ('MEMORY WindowsFree={0:N2}GiB, Minikube={1:N1}%' -f $freeGiB, $pct)
    if ($freeGiB -lt $MinWindowsFreeGiB) { throw ('LOW_WINDOWS_MEMORY: {0:N2}GiB < {1:N2}GiB' -f $freeGiB,$MinWindowsFreeGiB) }
    if ($pct -gt $MaxMinikubeMemoryPercent) { throw ('HIGH_MINIKUBE_MEMORY: {0:N1}% > {1}%' -f $pct,$MaxMinikubeMemoryPercent) }
}
function CheckCluster {
    $node = KubectlJson @('--context','minikube','get','nodes')
    $ready = @($node.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0 })
    Require ($ready.Count -gt 0) 'No Ready Kubernetes node.'
    $deploy = KubectlJson @('--context','minikube','-n','default','get','deployment','web-service')
    Require ($deploy.status.readyReplicas -ge 1) 'Application has no ready replica.'
    $mon = KubectlJson @('--context','minikube','-n','monitoring','get','pods','-l','app.kubernetes.io/name=prometheus')
    Log ("Ready node(s)=$($ready.Count), app ready replicas=$($deploy.status.readyReplicas)")
    $null = $mon
    $hpas = KubectlJson @('--context','minikube','-n','default','get','hpa')
    $sos = KubectlJson @('--context','minikube','-n','default','get','scaledobjects')
    $unrelated = @($hpas.items | Where-Object { $_.metadata.name -ne 'web-service-hpa-cpu' })
    $unrelated += @($sos.items | Where-Object { $_.metadata.name -ne 'web-service-keda-custom-raw' })
    Require ($unrelated.Count -eq 0) 'Unexpected autoscaler exists in namespace default. Refusing to modify.'
    Require (-not (@($hpas.items).Count -gt 0 -and @($sos.items).Count -gt 0)) 'Both HPA and KEDA are active; resolve conflict first.'
}
function StartManaged([string]$exe,[string]$commandLine,[string]$label) {
    $folder = Join-Path $env:TEMP 'autoscaling-automation'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $stamp = [guid]::NewGuid().ToString('N').Substring(0,8)
    $out = Join-Path $folder "$label-$stamp.stdout.log"
    $err = Join-Path $folder "$label-$stamp.stderr.log"
    $p = Start-Process -FilePath $exe -ArgumentList $commandLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    [void]$script:ownedProcesses.Add($p)
    return [pscustomobject]@{Process=$p;Stdout=$out;Stderr=$err}
}
function StopOwned([object]$p) {
    if ($null -eq $p) { return }
    try { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { }
}
function StartPortForward([string]$kind,[string]$resource,[int]$port,[string]$testUri) {
    if (UriHealthy $testUri) { Log "Reusing existing endpoint: $testUri"; return }
    Log "Starting $kind port-forward on 127.0.0.1:$port"
    $p = StartManaged $script:kubectl "--context minikube -n $kind port-forward $resource $($port):$port --address 127.0.0.1" "pf-$port"
    for ($i=0; $i -lt 20; $i++) {
        if (UriHealthy $testUri) { return }
        $p.Process.Refresh()
        if ($p.Process.HasExited) { break }
        Start-Sleep -Seconds 1
    }
    throw "Port-forward failed: $testUri. Check $($p.Stderr)"
}
function StartBalancedUrl {
    # A separate NodePort Service forwards to all Ready pods through Kubernetes Service routing.
    # On Windows/Docker driver, `minikube service --url` usually creates a local SSH tunnel.
    $service = @{
        apiVersion='v1'; kind='Service'; metadata=@{name='web-service-bench';namespace='default';labels=@{'app.kubernetes.io/part-of'='web-service-autoscaling-optimization';'autoscaling-automation'='temporary'}}
        spec=@{type='NodePort';selector=@{'app.kubernetes.io/name'='web-service-autoscaling';'app.kubernetes.io/component'='api'};ports=@(@{name='http';port=8000;targetPort=8000;protocol='TCP'})}
    }
    $pre = KubectlJson @('--context','minikube','-n','default','get','services')
    Require (@($pre.items | Where-Object { $_.metadata.name -eq 'web-service-bench' }).Count -eq 0) 'Temporary benchmark service already exists. Refusing to overwrite.'
    $tempYaml = Join-Path $script:reportDir 'bench-service.json'
    $service | ConvertTo-Json -Depth 10 | Set-Content -Path $tempYaml -Encoding UTF8
    Kube @('--context','minikube','apply','-f',$tempYaml)
    $script:benchServiceOwned = $true
    Log 'Starting Minikube NodePort service tunnel (load-balanced Service route).'
    $tunnel = StartManaged $script:minikube '-p minikube service web-service-bench --namespace default --url' 'minikube-service'
    for ($i=0; $i -lt 30; $i++) {
        $text = if (Test-Path $tunnel.Stdout) { Get-Content $tunnel.Stdout -Raw -ErrorAction SilentlyContinue } else { '' }
        $urls = [regex]::Matches([string]$text,'http://(?:127\.0\.0\.1|localhost|[0-9.]+):\d+')
        foreach ($u in $urls) {
            $url = $u.Value.Replace('localhost','127.0.0.1')
            if (UriHealthy "$url/health") { Log "Service-balanced URL: $url"; return $url }
        }
        $tunnel.Process.Refresh()
        if ($tunnel.Process.HasExited -and $urls.Count -eq 0) { break }
        Start-Sleep -Seconds 1
    }
    throw "Minikube Service tunnel not ready. Review $($tunnel.Stdout), $($tunnel.Stderr). Full benchmarking will not fall back to pod port-forward."
}
function SwitchPolicy([string]$policy) {
    Log "Switching autoscaler: $policy"
    $hpa = KubectlJson @('--context','minikube','-n','default','get','hpa')
    $so  = KubectlJson @('--context','minikube','-n','default','get','scaledobjects')
    if (@($hpa.items | Where-Object { $_.metadata.name -eq 'web-service-hpa-cpu' }).Count -gt 0) {
        Kube @('--context','minikube','-n','default','delete','hpa','web-service-hpa-cpu','--wait=true')
    }
    if (@($so.items | Where-Object { $_.metadata.name -eq 'web-service-keda-custom-raw' }).Count -gt 0) {
        Kube @('--context','minikube','-n','default','delete','scaledobject','web-service-keda-custom-raw','--wait=true')
    }
    # The deployment's replica count is reset ONLY while no autoscaler manages it.
    Kube @('--context','minikube','-n','default','scale','deployment/web-service','--replicas=1')
    Kube @('--context','minikube','-n','default','rollout','status','deployment/web-service','--timeout=120s')
    CheckMemory
    $file = if ($policy -eq 'baseline-cpu') { Join-Path $root 'k8s/autoscaling/hpa-cpu.yaml' } else { Join-Path $root 'k8s/autoscaling/keda-custom-raw.yaml' }
    Kube @('--context','minikube','apply','-f',$file)
    $policyReady = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Start-Sleep -Seconds 5
        $hpaNow = KubectlJson @('--context','minikube','-n','default','get','hpa')
        if (@($hpaNow.items).Count -ne 1) { continue }
        if ($policy -eq 'baseline-cpu') {
            $policyReady = $true
            break
        }
        $soNow = KubectlJson @('--context','minikube','-n','default','get','scaledobjects')
        if (@($soNow.items).Count -ne 1) { continue }
        $readyConditions = @($soNow.items[0].status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
        if ($readyConditions.Count -gt 0) { $policyReady = $true; break }
    }
    Require $policyReady "Autoscaler $policy failed to become Ready within verification window."
}
function Fingerprint([string]$policy,[string]$scenario,[string]$endpoint) {
    $scriptPath = if ($scenario -eq 'fault') { Join-Path $root 'load-tests/fault-safe-workload.js' } else { Join-Path $root "load-tests/$scenario-workload.js" }
    $policyPath = if ($policy -eq 'baseline-cpu') { Join-Path $root 'k8s/autoscaling/hpa-cpu.yaml' } else { Join-Path $root 'k8s/autoscaling/keda-custom-raw.yaml' }
    $parts = @($policy,$scenario,$endpoint,$Rate,$MaxVus,$Iterations,$WorkTime,$MaxQueueLimit,$SampleSeconds,(Get-Content $scriptPath -Raw),(Get-Content $policyPath -Raw),(Get-Content (Join-Path $root 'load-tests/common.js') -Raw)) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($parts)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function RunK6([string]$policy,[string]$scenario,[string]$endpoint) {
    CheckMemory
    $fingerprint = Fingerprint $policy $scenario $endpoint
    $key = "$policy-$scenario-$endpoint-$fingerprint"
    $cpFile = Join-Path $script:checkpointDir "$key.json"
    if ($Resume -and (Test-Path $cpFile)) {
        $cp = Get-Content $cpFile -Raw | ConvertFrom-Json
        if ($cp.status -in @('complete','complete_exit_unknown') -and (Test-Path $cp.k6_summary) -and (Test-Path $cp.prometheus_csv)) {
            Log "SKIP completed checkpoint: $key"
            [void]$script:runResults.Add($cp)
            return
        }
    }
    $dir = Join-Path $root ("data/$policy/auto-$scenario-$endpoint-$runStarted")
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $scriptPath = if ($scenario -eq 'fault') { Join-Path $root 'load-tests/fault-safe-workload.js' } else { Join-Path $root "load-tests/$scenario-workload.js" }
    $outLog = Join-Path $dir 'k6-console.log'
    $errLog = Join-Path $dir 'k6-stderr.log'
    $rawFile = Join-Path $dir 'k6-raw.json'
    $summary = Join-Path $dir 'k6-summary.json'
    $effectiveWorkTime = if ($scenario -eq 'fault') { 1.0 } else { $WorkTime }
    $effectiveQueueLimit = if ($scenario -eq 'fault') { 10 } else { $MaxQueueLimit }
    $k6args = @('run','--out',('"json=' + $rawFile + '"'), '-e',('"BASE_URL=' + $script:baseUrl + '"'), '-e',('ENDPOINT='+$endpoint), '-e',('ITERATIONS='+$Iterations), '-e',('WORK_TIME='+([string]$effectiveWorkTime)), '-e',('MAX_QUEUE_LIMIT='+$effectiveQueueLimit), '-e',('RATE='+$Rate), '-e',('MAX_VUS='+$MaxVus), '-e',('"SUMMARY_FILE='+$summary+'"'))
    if ($scenario -eq 'fault') { $k6args += @('-e',('FAULT_RATE='+([math]::Min(12, $Rate * 6)))) }
    $k6args += ('"' + $scriptPath + '"')
    Log "RUN $policy / $scenario / $endpoint (RATE=$Rate MAX_VUS=$MaxVus)"
    $begin = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $metadata = @{policy=$policy;scenario=$scenario;endpoint=$endpoint;rate=$Rate;max_vus=$MaxVus;iterations=$Iterations;work_time=$effectiveWorkTime;queue_limit=$effectiveQueueLimit;fingerprint=$fingerprint;load_balanced=($Mode -eq 'Full');base_url=$script:baseUrl;started_unix=$begin}
    $metadata | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'metadata.json') -Encoding UTF8
    $proc = Start-Process -FilePath $script:k6 -ArgumentList ($k6args -join ' ') -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $killed = $false
    $stopReason = $null
    while ($true) {
        Start-Sleep -Seconds 8
        $proc.Refresh()
        if ($proc.HasExited) { break }
        try {
            CheckMemory
            $d = KubectlJson @('--context','minikube','-n','default','get','deployment','web-service')
            $pods = KubectlJson @('--context','minikube','-n','default','get','pods','-l','app.kubernetes.io/name=web-service-autoscaling')
            foreach ($pod in $pods.items) {
                if ($pod.status.phase -eq 'Failed') { throw "Pod failed: $($pod.metadata.name)" }
                foreach ($c in $pod.status.containerStatuses) {
                    if ($null -ne $c -and $c.restartCount -gt 0) { throw "Pod restarted: $($pod.metadata.name)" }
                }
            }
            Log "Replicas ready=$($d.status.readyReplicas), desired=$($d.spec.replicas)"
        } catch {
            $stopReason = $_.Exception.Message
            Log "SAFETY STOP: $stopReason"
            StopOwned $proc
            $killed = $true
            break
        }
    }
    $proc.WaitForExit()
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $exitCode = $proc.ExitCode
    $metadata.ended_unix = $end
    $metadata.k6_exit_code = $exitCode
    $metadata.safety_stop = $stopReason
    $metadata | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'metadata.json') -Encoding UTF8
    Log "k6 exit=$exitCode; exporting Prometheus series."
    $collectorCode = -1
    try {
        & $script:python (Join-Path $root 'scripts/collect-metrics.py') '--prometheus-url' $script:promUrl '--start' ([string]($begin-30)) '--end' ([string]$end) '--step' ([string]$SampleSeconds) '--output' $dir
        $collectorCode = $LASTEXITCODE
    } catch { Log "METRICS COLLECTION ERROR: $($_.Exception.Message)" }
    $csv = Join-Path $dir 'prometheus_timeseries.csv'
    $artifactVerified = $false

if (-not $killed -and $collectorCode -eq 0 -and
    (Test-Path $summary) -and (Test-Path $csv)) {

    try {
        $sd = Get-Content $summary -Raw | ConvertFrom-Json

        $requests = [double]$sd.metrics.http_reqs.values.count
        $dropped = 0

        if ($null -ne $sd.metrics.dropped_iterations) {
            $dropped = [double]$sd.metrics.dropped_iterations.values.count
        }

        $thresholdsOK = $true

        foreach ($metric in $sd.metrics.PSObject.Properties) {
            if ($null -ne $metric.Value.thresholds) {
                foreach ($threshold in $metric.Value.thresholds.PSObject.Properties) {
                    if ($threshold.Value.ok -ne $true) {
                        $thresholdsOK = $false
                    }
                }
            }
        }

        $expectedSeconds = switch ($scenario) {
            'step'     { 240 }
            'spike'    { 145 }
            'periodic' { 300 }
            'fault'    { 90 }
        }

        $csvRows = @(Import-Csv $csv).Count

        $artifactVerified = (
            $requests -gt 0 -and
            $dropped -eq 0 -and
            $thresholdsOK -and
            $csvRows -gt 0 -and
            ($end - $begin) -ge ($expectedSeconds - 2)
        )
    }
    catch {
        Log "Artifact verification failed: $($_.Exception.Message)"
    }
}

$status = if (-not $killed -and $exitCode -eq 0 -and
    $collectorCode -eq 0 -and $artifactVerified) {
    'complete'
}
elseif (-not $killed -and $null -eq $exitCode -and $artifactVerified) {
    'complete_exit_unknown'
}
else {
    'failed'
}

if ($status -eq 'complete_exit_unknown') {
    Log 'WARNING: k6 artifacts verified; process exit code unavailable.'
}
    $result = [pscustomobject]@{key=$key;policy=$policy;scenario=$scenario;endpoint=$endpoint;status=$status;out=$dir;k6_exit_code=$exitCode;collector_exit_code=$collectorCode;safety_stop=$stopReason;k6_summary=$summary;prometheus_csv=$csv;started_unix=$begin;ended_unix=$end;load_balanced=($Mode -eq 'Full')}
    $result | ConvertTo-Json -Depth 8 | Set-Content $cpFile -Encoding UTF8
    [void]$script:runResults.Add($result)
    if ($status -eq 'failed') { throw "Run failed ($key). Inspect $outLog and $errLog; results retained in $dir" }
    Log "COMPLETE: $dir"
}

try {
    foreach ($file in @('app/main.py','k8s/base/deployment.yaml','k8s/autoscaling/hpa-cpu.yaml','k8s/autoscaling/keda-custom-raw.yaml','scripts/collect-metrics.py','load-tests/common.js','load-tests/step-workload.js','load-tests/spike-workload.js','load-tests/periodic-workload.js','load-tests/fault-safe-workload.js')) {
        Require (Test-Path (Join-Path $root $file)) "Missing project file: $file"
    }
    $script:kubectl = Tool 'kubectl'
    $script:docker = Tool 'docker'
    $script:k6 = Tool 'k6'
    $script:python = Tool 'python'
    & $script:python --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Python executable is not working. Check PATH.' }
    if ($Mode -eq 'Full') { $script:minikube = Tool 'minikube' }
    CheckCluster
    CheckMemory
    Log "Preflight PASS. Mode=$Mode"
    if ($Mode -eq 'Preflight') {
        Log 'NO LOAD and NO KUBERNETES CHANGES. Use -Mode Smoke or -Mode Full to execute.'
        return
    }
    New-Item -ItemType Directory -Force -Path $reportDir, $checkpointDir | Out-Null
    # A local Prometheus port-forward is only for metadata collection, not load balancing.
    StartPortForward 'monitoring' 'service/monitoring-kube-prometheus-prometheus' 9090 'http://127.0.0.1:9090/-/ready'
    if ($Mode -eq 'Smoke') {
        StartPortForward 'default' 'service/web-service' 8000 'http://127.0.0.1:8000/health'
        $script:baseUrl = 'http://127.0.0.1:8000'
        Log 'SMOKE only: single-pod port-forward, NOT a multi-replica benchmark.'
        SwitchPolicy 'baseline-cpu'
        RunK6 'baseline-cpu' 'step' 'cpu'
    }
    else {
        $script:baseUrl = StartBalancedUrl
        $matrix = @(
            @{scenario='step';endpoint='cpu'},
            @{scenario='spike';endpoint='queue'},
            @{scenario='periodic';endpoint='queue'}
        )
        if ($IncludeFault) { $matrix += @{scenario='fault';endpoint='queue'} }
        foreach ($policy in @('baseline-cpu','custom-unoptimized')) {
            foreach ($job in $matrix) {
                # Reset to one replica before each measurement; never force replica count while an autoscaler is active.
                # SwitchPolicy handles removal/reapplication safely.
                SwitchPolicy $policy
                RunK6 $policy $job.scenario $job.endpoint
            }
        }
    }
    Log 'EXPERIMENT BATCH COMPLETE.'
}
catch {
    $failureReason = $_.Exception.Message
    Write-Host "[FAILED] $failureReason" -ForegroundColor Red
}
finally {
    if (Test-Path $reportDir) {
        $manifest = @{mode=$Mode;timestamp=$runStarted;error=$failureReason;results=@($runResults.ToArray());notes='Smoke uses single-pod port-forward; Full uses temporary NodePort Service tunnel. No performance improvement asserted automatically.'}
        $manifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $reportDir 'run-report.json') -Encoding UTF8
        Log "Report: $(Join-Path $reportDir 'run-report.json')"
    }
    foreach ($proc in $ownedProcesses) { StopOwned $proc }
    if ($benchServiceOwned) {
        Log 'Removing temporary benchmark NodePort Service.'
        try { & $kubectl --context minikube -n default delete service web-service-bench --ignore-not-found=true | Out-Host } catch { Log 'WARNING: remove web-service-bench manually.' }
    }
    # The current policy remains applied intentionally; deleting it automatically could affect later experiments.
}
if ($failureReason) { exit 1 }
