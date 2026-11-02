
#Requires -Version 5.1

<#
.SYNOPSIS
    Initializes and validates a local Kubernetes environment.

.DESCRIPTION
    Uses Docker Desktop and Minikube to create or reuse a Kubernetes
    cluster, enable Metrics Server, and verify resource metrics.

    Existing Minikube profiles retain their configured CPU and memory.
    The script does not delete clusters or modify Docker settings.

.EXAMPLE
    .\scripts\setup-cluster.ps1

.EXAMPLE
    .\scripts\setup-cluster.ps1 -Profile minikube -Cpus 2 -MemoryMiB 3072
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Profile = "minikube",

    [ValidateRange(2, 16)]
    [int]$Cpus = 2,

    [ValidateRange(2048, 32768)]
    [int]$MemoryMiB = 3072
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [ValidateSet("INFO", "OK", "WARN", "ERROR")]
        [string]$Level,

        [string]$Message
    )

    $colors = @{
        INFO  = "Cyan"
        OK    = "Green"
        WARN  = "Yellow"
        ERROR = "Red"
    }

    Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
}

function Assert-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Command $($Arguments -join ' ')"
    }
}

try {
    # --------------------------------------------------------
    # 1. Validate required development tools
    # --------------------------------------------------------

    Write-Log INFO "Checking required development tools..."

    foreach ($tool in @("docker", "minikube", "kubectl", "helm")) {
        Assert-Command $tool
        Write-Log OK "$tool is available"
    }

    # --------------------------------------------------------
    # 2. Verify Docker Engine availability
    # --------------------------------------------------------

    Write-Log INFO "Checking Docker Engine..."

    $memoryOutput = & docker info --format '{{.MemTotal}}'

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Engine is unavailable. Start Docker Desktop."
    }

    $dockerMemoryBytes = [long]::Parse(
        ($memoryOutput | Out-String).Trim()
    )

    $dockerMemoryMiB = [math]::Floor(
        $dockerMemoryBytes / 1MB
    )

    Write-Log OK "Docker Engine is running"
    Write-Log INFO "Docker memory limit: $dockerMemoryMiB MiB"

    # --------------------------------------------------------
    # 3. Create or reuse the Minikube cluster
    # --------------------------------------------------------

    Write-Log INFO "Checking Minikube profile: $Profile"

    $profilePath = Join-Path $env:USERPROFILE `
        ".minikube\profiles\$Profile\config.json"

    if (Test-Path $profilePath) {
        Write-Log INFO "Existing profile detected. Reusing cluster."

        Invoke-Checked -Command "minikube" -Arguments @(
            "start",
            "--profile=$Profile",
            "--driver=docker"
        )
    }
    else {
        $requiredMemoryMiB = $MemoryMiB + 512

        if ($dockerMemoryMiB -lt $requiredMemoryMiB) {
            throw "Insufficient Docker memory. Required: $requiredMemoryMiB MiB; available limit: $dockerMemoryMiB MiB."
        }

        Write-Log INFO "Creating Minikube cluster..."
        Write-Log INFO "CPU: $Cpus | Memory: $MemoryMiB MiB"

        Invoke-Checked -Command "minikube" -Arguments @(
            "start",
            "--profile=$Profile",
            "--driver=docker",
            "--cpus=$Cpus",
            "--memory=$MemoryMiB"
        )
    }

    # --------------------------------------------------------
    # 4. Verify Kubernetes node readiness
    # --------------------------------------------------------

    Write-Log INFO "Checking Kubernetes node readiness..."

    Invoke-Checked -Command "kubectl" -Arguments @(
        "--context", $Profile,
        "wait",
        "--for=condition=Ready",
        "nodes",
        "--all",
        "--timeout=180s"
    )

    Invoke-Checked -Command "kubectl" -Arguments @(
        "--context", $Profile,
        "get", "nodes", "-o", "wide"
    )

    Write-Log OK "Kubernetes nodes are ready"

    # --------------------------------------------------------
    # 5. Enable Kubernetes Metrics Server
    # --------------------------------------------------------

    Write-Log INFO "Enabling Metrics Server..."

    Invoke-Checked -Command "minikube" -Arguments @(
        "addons", "enable", "metrics-server",
        "--profile=$Profile"
    )

    Invoke-Checked -Command "kubectl" -Arguments @(
        "--context", $Profile,
        "-n", "kube-system",
        "rollout", "status",
        "deployment/metrics-server",
        "--timeout=180s"
    )

    Write-Log OK "Metrics Server deployment is ready"

    # --------------------------------------------------------
    # 6. Verify Kubernetes resource metrics
    # --------------------------------------------------------

    Write-Log INFO "Verifying resource metrics..."

    $metricsReady = $false
    $maxAttempts = 12

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        & kubectl --context $Profile top nodes

        if ($LASTEXITCODE -eq 0) {
            $metricsReady = $true
            break
        }

        Write-Log WARN "Metrics API unavailable ($attempt/$maxAttempts)"

        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    if (-not $metricsReady) {
        throw "Metrics API is unavailable. Inspect Metrics Server logs and APIService status."
    }

    # --------------------------------------------------------
    # 7. Display setup summary
    # --------------------------------------------------------

    Write-Host ""
    Write-Log OK "Kubernetes cluster setup completed successfully."
    Write-Host ""
    Write-Host "Cluster       : $Profile"
    Write-Host "Driver        : Docker"
    Write-Host "Node status   : Ready"
    Write-Host "Metrics Server: Available"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Log ERROR $_.Exception.Message
    exit 1
}
