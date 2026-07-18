# Discover and invoke lifecycle hooks supplied by Dumplings submodules.

$Script:DumplingsModuleHookNames = @(
  'RunnerStarting'
  'WorkerStarting'
  'BeforeTask'
  'AfterTask'
  'WorkerStopping'
  'BeforeForcedWorkerStop'
  'RunnerStopping'
)
$Script:DumplingsCleanupHookNames = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]@('AfterTask', 'WorkerStopping', 'BeforeForcedWorkerStop', 'RunnerStopping'),
  [System.StringComparer]::Ordinal
)

function Get-DumplingsModuleHookPlan {
  <#
  .SYNOPSIS
    Discover lifecycle hook scripts supplied by Dumplings submodules.
  .PARAMETER ModulePath
    The directory containing Dumplings submodules.
  .OUTPUTS
    A path-only hook plan that can be shared with thread-job runspaces.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ModulePath
  )

  $Hooks = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::Ordinal)
  foreach ($HookName in $Script:DumplingsModuleHookNames) {
    $HookPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($ModuleDirectory in Get-ChildItem -LiteralPath $ModulePath -Directory | Sort-Object -Property Name) {
      $HookPath = Join-Path $ModuleDirectory.FullName 'Hooks' "${HookName}.ps1"
      if (Test-Path -LiteralPath $HookPath -PathType Leaf) {
        $HookPaths.Add((Convert-Path -LiteralPath $HookPath))
      }
    }
    $Hooks[$HookName] = $HookPaths.ToArray()
  }

  return [pscustomobject]@{
    ModulePath = Convert-Path -LiteralPath $ModulePath
    Hooks      = $Hooks
  }
}

function Invoke-DumplingsModuleHook {
  <#
  .SYNOPSIS
    Invoke one lifecycle phase from a discovered module hook plan.
  .PARAMETER Plan
    The plan returned by Get-DumplingsModuleHookPlan.
  .PARAMETER Name
    The lifecycle phase to invoke.
  .PARAMETER Context
    Mutable context shared by every hook in this lifecycle phase.
  .DESCRIPTION
    Startup and before hooks run in module-name order and stop on the first
    failure. Cleanup and after hooks run in reverse order, attempt every hook,
    and throw an aggregate exception after cleanup completes.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    $Plan,

    [Parameter(Mandatory)]
    [ValidateSet('RunnerStarting', 'WorkerStarting', 'BeforeTask', 'AfterTask', 'WorkerStopping', 'BeforeForcedWorkerStop', 'RunnerStopping')]
    [string]$Name,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$Context
  )

  if (-not $Plan.Hooks.ContainsKey($Name)) { return }

  [string[]]$HookPaths = @($Plan.Hooks[$Name])
  $IsCleanup = $Script:DumplingsCleanupHookNames.Contains($Name)
  if ($IsCleanup) { [array]::Reverse($HookPaths) }

  $Failures = [System.Collections.Generic.List[System.Exception]]::new()
  foreach ($HookPath in $HookPaths) {
    try {
      $Context.HookName = $Name
      $Context.HookPath = $HookPath
      $null = & $HookPath -Context $Context
    } catch {
      $Failure = [System.InvalidOperationException]::new(
        "Dumplings module hook '${Name}' failed at '${HookPath}': $($_.Exception.Message)",
        $_.Exception
      )
      if (-not $IsCleanup) { throw $Failure }
      $Failures.Add($Failure)
    }
  }

  if ($Failures.Count -gt 0) {
    throw [System.AggregateException]::new(
      "One or more Dumplings module hooks failed during '${Name}'.",
      [System.Collections.Generic.IEnumerable[System.Exception]]$Failures
    )
  }
}

Export-ModuleMember -Function Get-DumplingsModuleHookPlan, Invoke-DumplingsModuleHook
