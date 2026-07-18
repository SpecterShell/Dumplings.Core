<#
.SYNOPSIS
  Resolves dependencies between Dumplings shared-data tasks and package tasks.
.DESCRIPTION
  Dependencies are declared through DependsOn in each task's Config.yaml.
  Literal $Global:DumplingsStorage accesses are analyzed only to detect missing
  declarations for shared-data tasks whose names start with #.
#>

function Get-DumplingsTaskStorageKey {
  <#
  .SYNOPSIS
    Reads literal DumplingsStorage keys referenced by a task script.
  .PARAMETER Path
    The path to a task script.
  .PARAMETER Access
    Return all referenced keys, or only keys directly assigned by the script.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param (
    [Parameter(Mandatory, ValueFromPipeline)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [ValidateSet('All', 'Write')]
    [string]$Access = 'All'
  )

  process {
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
      (Convert-Path -LiteralPath $Path),
      [ref]$Tokens,
      [ref]$ParseErrors
    )

    if ($ParseErrors.Count -gt 0) {
      $Messages = @($ParseErrors | ForEach-Object -Process { $_.Message }) -join '; '
      throw "Failed to parse task script '${Path}': ${Messages}"
    }

    $Keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $StorageExpression = '$Global:DumplingsStorage'
    $StorageReferences = if ($Access -eq 'Write') {
      @($Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
          ForEach-Object -Process { $_.Left })
    } else {
      $Ast.FindAll({
          param($Node)
          $Node -is [System.Management.Automation.Language.MemberExpressionAst] -or
            $Node -is [System.Management.Automation.Language.IndexExpressionAst]
        }, $true)
    }

    foreach ($Reference in $StorageReferences) {
      $Key = if (
        $Reference -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $Reference.Expression.Extent.Text -ceq $StorageExpression -and
        $Reference.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]
      ) {
        $Reference.Member.Value
      } elseif (
        $Reference -is [System.Management.Automation.Language.IndexExpressionAst] -and
        $Reference.Target.Extent.Text -ceq $StorageExpression -and
        $Reference.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]
      ) {
        $Reference.Index.Value
      }

      if (-not [string]::IsNullOrWhiteSpace($Key)) {
        $null = $Keys.Add($Key)
      }
    }

    $Keys | Sort-Object
  }
}

function Resolve-DumplingsTaskDependency {
  <#
  .SYNOPSIS
    Builds an ordered execution plan from explicit task dependencies.
  .PARAMETER TaskDirectory
    The directory containing task folders.
  .PARAMETER TaskName
    The task names explicitly selected for execution.
  .OUTPUTS
    An object containing ordered TaskNames and a Dependencies dictionary.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$TaskDirectory,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$TaskName
  )

  $TaskPaths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
  $ConfigPaths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
  foreach ($ConfigFile in Get-ChildItem -LiteralPath $TaskDirectory -Filter 'Config.yaml' -File -Recurse -Depth 1) {
    $Name = $ConfigFile.Directory.Name
    $ScriptPath = Join-Path $ConfigFile.Directory.FullName 'Script.ps1'
    if (-not $TaskPaths.TryAdd($Name, $ScriptPath)) {
      throw "Duplicate task name found: ${Name}"
    }
    $ConfigPaths[$Name] = $ConfigFile.FullName
  }

  $ProvidersByKey = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $StorageKeysByTask = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($ProviderName in @($TaskPaths.Keys | Where-Object { $_.StartsWith('#', [System.StringComparison]::Ordinal) } | Sort-Object)) {
    if (-not (Test-Path -LiteralPath $TaskPaths[$ProviderName] -PathType Leaf)) {
      throw "The dependency task '${ProviderName}' does not contain Script.ps1"
    }
    $ProviderKeys = [string[]]@(Get-DumplingsTaskStorageKey -Path $TaskPaths[$ProviderName] -Access Write)
    $StorageKeysByTask[$ProviderName] = [string[]]@(Get-DumplingsTaskStorageKey -Path $TaskPaths[$ProviderName])
    foreach ($Key in $ProviderKeys) {
      if ($ProvidersByKey.ContainsKey($Key)) {
        throw "DumplingsStorage key '${Key}' has multiple providers: '$($ProvidersByKey[$Key])' and '${ProviderName}'"
      }
      $ProvidersByKey[$Key] = $ProviderName
    }
  }

  $SelectedTasks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $PendingTasks = [System.Collections.Generic.Queue[string]]::new()
  foreach ($RequestedName in $TaskName) {
    if (-not $TaskPaths.ContainsKey($RequestedName)) {
      throw "The selected task '${RequestedName}' does not exist"
    }
    if ($SelectedTasks.Add($RequestedName)) {
      $PendingTasks.Enqueue($RequestedName)
    }
  }

  $Dependencies = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::Ordinal)
  $UndeclaredStorageDependencies = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::Ordinal)
  while ($PendingTasks.Count -gt 0) {
    $CurrentTask = $PendingTasks.Dequeue()

    try {
      $TaskConfig = Get-Content -LiteralPath $ConfigPaths[$CurrentTask] -Raw | ConvertFrom-Yaml -Ordered
    } catch {
      throw "Failed to read task config '$($ConfigPaths[$CurrentTask])': ${_}"
    }
    if (-not $TaskConfig -or $TaskConfig -isnot [System.Collections.IDictionary]) {
      throw "The task config '$($ConfigPaths[$CurrentTask])' is not a valid dictionary"
    }

    $CurrentDependencies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($TaskConfig.Contains('DependsOn') -and $null -ne $TaskConfig.DependsOn) {
      $DependencyValues = if ($TaskConfig.DependsOn -is [string]) {
        @($TaskConfig.DependsOn)
      } elseif ($TaskConfig.DependsOn -is [System.Collections.IEnumerable] -and $TaskConfig.DependsOn -isnot [System.Collections.IDictionary]) {
        @($TaskConfig.DependsOn)
      } else {
        throw "DependsOn for task '${CurrentTask}' must be a task name or an array of task names"
      }

      foreach ($DependencyValue in $DependencyValues) {
        if ($DependencyValue -isnot [string] -or [string]::IsNullOrWhiteSpace($DependencyValue)) {
          throw "DependsOn for task '${CurrentTask}' contains an invalid task name"
        }
        if (-not $TaskPaths.ContainsKey($DependencyValue)) {
          throw "Task '${CurrentTask}' depends on missing task '${DependencyValue}'"
        }
        $null = $CurrentDependencies.Add($DependencyValue)
      }
    }

    $Dependencies[$CurrentTask] = [string[]]@($CurrentDependencies | Sort-Object)
    foreach ($DependencyName in $Dependencies[$CurrentTask]) {
      if ($SelectedTasks.Add($DependencyName)) {
        $PendingTasks.Enqueue($DependencyName)
      }
    }

    # Storage analysis validates explicit declarations but never changes the plan.
    if (-not $StorageKeysByTask.ContainsKey($CurrentTask)) {
      if (-not (Test-Path -LiteralPath $TaskPaths[$CurrentTask] -PathType Leaf)) {
        # Preserve the runner's existing per-task initialization failure instead
        # of preventing every other selected task from being planned.
        $StorageKeysByTask[$CurrentTask] = [string[]]@()
      } else {
        $StorageKeysByTask[$CurrentTask] = [string[]]@(Get-DumplingsTaskStorageKey -Path $TaskPaths[$CurrentTask])
      }
    }

    $InferredDependencies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($Key in $StorageKeysByTask[$CurrentTask]) {
      if ($ProvidersByKey.ContainsKey($Key)) {
        $ProviderName = $ProvidersByKey[$Key]
        if (-not $ProviderName.Equals($CurrentTask, [System.StringComparison]::OrdinalIgnoreCase)) {
          $null = $InferredDependencies.Add($ProviderName)
        }
      }
    }

    $UndeclaredDependencies = [string[]]@($InferredDependencies | Where-Object { -not $CurrentDependencies.Contains($_) } | Sort-Object)
    $UndeclaredStorageDependencies[$CurrentTask] = $UndeclaredDependencies
    if ($UndeclaredDependencies.Count -gt 0) {
      Write-Warning "Task '${CurrentTask}' accesses DumplingsStorage supplied by undeclared dependency task(s): $($UndeclaredDependencies -join ', ')"
    }
  }

  # Kahn's algorithm provides a deterministic plan and detects dependency cycles.
  $Remaining = [System.Collections.Generic.HashSet[string]]::new($SelectedTasks, [System.StringComparer]::Ordinal)
  $OrderedTasks = [System.Collections.Generic.List[string]]::new()
  while ($Remaining.Count -gt 0) {
    $ReadyTasks = @($Remaining | Where-Object {
        $Candidate = $_
        -not $Dependencies[$Candidate].Where({ $Remaining.Contains($_) }, 'First')
      } | Sort-Object)

    if ($ReadyTasks.Count -eq 0) {
      throw "A task dependency cycle was detected among: $(@($Remaining | Sort-Object) -join ', ')"
    }

    foreach ($ReadyTask in $ReadyTasks) {
      $OrderedTasks.Add($ReadyTask)
      $null = $Remaining.Remove($ReadyTask)
    }
  }

  return [pscustomobject]@{
    TaskNames                     = [string[]]$OrderedTasks.ToArray()
    Dependencies                  = $Dependencies
    StorageKeys                   = $StorageKeysByTask
    ProvidersByKey                = $ProvidersByKey
    UndeclaredStorageDependencies = $UndeclaredStorageDependencies
  }
}

Export-ModuleMember -Function Get-DumplingsTaskStorageKey, Resolve-DumplingsTaskDependency
