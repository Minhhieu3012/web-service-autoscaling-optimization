
# Safely clean up Helm-managed monitoring components
# in the local Minikube development environment.
#
# Default: preview only.
# Destructive operations require -Execute and confirmation.

[CmdletBinding()]
param(
    [ValidateSet("All", "Keda", "Monitoring")]
    [string]$Scope = "All",

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$KubeContext = "minikube"

function Assert-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Get-ReleaseInstalled {
    param(
        [string]$Release,
        [string]$Namespace
    )

    $result = & helm list `
        --namespace $Namespace `
        --kube-context $KubeContext `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect Helm releases in namespace '$Namespace'."
    }

    $json = ($result | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($json)) {
        return $false
    }

    $releases = @(ConvertFrom-Json -InputObject $json)

    foreach ($item in $releases) {
        if ($item.name -eq $Release) {
            return $true
        }
    }

    return $false
}

function Assert-NoKedaWorkloads {
    $resourceKinds = @(
        "scaledobjects.keda.sh",
        "scaledjobs.keda.sh"
    )

    foreach ($kind in $resourceKinds) {
        $result = & kubectl `
            --context $KubeContext `
            get $kind `
            --all-namespaces `
            --output json

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect '$kind'. KEDA cleanup aborted."
        }

        $data = ConvertFrom-Json -InputObject (
            ($result | Out-String).Trim()
        )

        if (@($data.items).Count -gt 0) {
            throw "Active '$kind' resources exist. KEDA cleanup aborted."
        }
    }
}

Write-Host "[INFO] Local Kubernetes cleanup"
Write-Host "[INFO] Context: $KubeContext"
Write-Host "[INFO] Scope: $Scope"

Assert-Command "helm"
Assert-Command "kubectl"

$contexts = @(& kubectl config get-contexts -o name)

if ($LASTEXITCODE -ne 0 -or $contexts -notcontains $KubeContext) {
    throw "Kubernetes context '$KubeContext' is unavailable."
}

$allTargets = @(
    [pscustomobject]@{
        Scope     = "Keda"
        Release   = "keda"
        Namespace = "keda"
    },
    [pscustomobject]@{
        Scope     = "Monitoring"
        Release   = "monitoring"
        Namespace = "monitoring"
    }
)

$selectedTargets = @(
    $allTargets | Where-Object {
        $Scope -eq "All" -or $_.Scope -eq $Scope
    }
)

$installedTargets = @()

foreach ($target in $selectedTargets) {
    $installed = Get-ReleaseInstalled `
        -Release $target.Release `
        -Namespace $target.Namespace

    if ($installed) {
        $installedTargets += $target

        Write-Host (
            "[FOUND] {0} in namespace {1}" -f `
            $target.Release, $target.Namespace
        )
    }
    else {
        Write-Host (
            "[SKIP] Release {0} is not installed." -f `
            $target.Release
        )
    }
}

if ($installedTargets.Count -eq 0) {
    Write-Host "[OK] Nothing to clean up."
    return
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "[DRY RUN] No resources were deleted."
    Write-Host "[INFO] To uninstall the selected releases, use -Execute."
    return
}

# Protect existing autoscaling experiments.
if (@($installedTargets | Where-Object {
    $_.Release -eq "keda"
}).Count -gt 0) {
    Assert-NoKedaWorkloads
}

Write-Host ""
Write-Warning "The selected Helm releases will be uninstalled."
Write-Warning "Source code, Docker, Minikube and namespaces will be preserved."

$confirmation = Read-Host "Type UNINSTALL to continue"

if ($confirmation -cne "UNINSTALL") {
    Write-Host "[CANCELLED] No resources were deleted."
    return
}

foreach ($target in $installedTargets) {
    Write-Host (
        "[INFO] Uninstalling {0} from {1}..." -f `
        $target.Release, $target.Namespace
    )

    & helm uninstall $target.Release `
        --namespace $target.Namespace `
        --kube-context $KubeContext `
        --wait `
        --timeout 3m

    if ($LASTEXITCODE -ne 0) {
        throw "Helm uninstall failed for '$($target.Release)'."
    }

    Write-Host "[OK] Removed Helm release: $($target.Release)"
}

Write-Host ""
Write-Host "[OK] Cleanup completed."
Write-Host "[INFO] Minikube cluster and local source files were preserved."
