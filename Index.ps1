<#
.SYNOPSIS
  A bootstrapping script to build and run tasks, in either single-thread mode or multi-threads mode
.PARAMETER Name
  The names of the tasks to run. Tasks declared through DependsOn in Config.yaml are included automatically. Leave blank to run all tasks
.PARAMETER Path
  The path to the folder containing the task files
.PARAMETER PassThru
  Pass the task objects to output
.PARAMETER ThrottleLimit
  The number of sub-threads used to run the tasks concurrently in multi-threads mode. Set it to 1 to run in single-thread mode
.PARAMETER Params
  Additional parameters to be used by model constructors and instances. See the source code of the models for more parameters
.EXAMPLE
  .\Index.ps1

  Run all the tasks in the default directory (The 'Tasks' folder in the same directory as the script)
.EXAMPLE
  .\Index.ps1 -Name 'A', 'B'

  Run tasks "A" and "B" in the default directory
.EXAMPLE
  .\Index.ps1 -Name 'A', 'B' -Path '/path/to/another/folder'

  Run tasks "A" and "B" in another directory
.EXAMPLE
  .\Index.ps1 -Name 'A', 'B' -ThrottleLimit 1

  Run tasks "A" and "B" in the default directory under single-thread mode
#>

#Requires -Version 7.4

[CmdletBinding()]
param (
  [Parameter(Position = 0, ValueFromPipeline, HelpMessage = 'The names of the tasks to run. Leave blank to run all tasks')]
  [ArgumentCompleter({ Join-Path ($args[4].Contains('Path') ? $args[4].Path : (Join-Path $PWD 'Tasks')) "$($args[2])*" 'Config.yaml' | Get-ChildItem -File | Select-Object -ExpandProperty Directory | Select-Object -ExpandProperty Name })]
  [string[]]$Name,

  [Parameter(Position = 1, HelpMessage = 'The path to the folder containing the task files')]
  [ValidateNotNullOrWhiteSpace()]
  [string]$Path = (Join-Path $PWD 'Tasks'),

  [Parameter(Position = 2, HelpMessage = 'Pass the task objects to output')]
  [switch]$PassThru = $false,

  [Parameter(Position = 3, HelpMessage = 'The number of sub-threads used to run the tasks concurrently in multi-threads mode. Set it to 1 to run in single-thread mode')]
  [ValidateScript({ $_ -gt 0 }, ErrorMessage = 'The number should be positive.')]
  [ushort]$ThrottleLimit = 1,

  [Parameter(Position = 4, DontShow, HelpMessage = 'Tell the script if it is running in a sub-thread to skip some regions')]
  [switch]$Parallel = $false,

  [Parameter(Position = 5, DontShow, HelpMessage = 'The ID of the thread')]
  [ushort]$WokID = 0,

  [Parameter(Position = 6, ValueFromRemainingArguments, HelpMessage = 'Additional parameters to be passed to the model instances')]
  [System.Collections.IEnumerable]$Params = @()
)

# Load runner infrastructure before the main thread builds shared state.
Import-Module (Join-Path $PSScriptRoot 'TaskDependency.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkerState.psm1') -Force

# Enable strict mode to avoid non-existent or empty properties from the API
Set-StrictMode -Version 3.0

# In CI, hide the progress bar to avoid pollutions to console output
if (Test-Path -Path Env:\CI) { $ProgressPreference = 'SilentlyContinue' }

# Force stop on error
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Log {
  <#
  .SYNOPSIS
    Write message to the host under specified level
  .DESCRIPTION
    Write message to the host under specified level
    The function aims to replace Write-Host which suppresses colorized output when the console output is redirected (e.g., CI)
  .PARAMETER Message
    The message content
  .PARAMETER Identifier
    The identifier to be prepended to the message
  .PARAMETER Level
    The message level
  #>
  param (
    [Parameter(Position = 0, ValueFromPipeline, Mandatory, HelpMessage = 'The message content')]
    $Object,

    [Parameter(HelpMessage = 'The identifier to be prepended to the message')]
    [string[]]$Identifier = $DumplingsLogIdentifier,

    [Parameter(HelpMessage = 'The message level')]
    [ValidateSet('Verbose', 'Log', 'Info', 'Warning', 'Error')]
    [string]$Level = 'Log'
  )

  process {
    $Color = switch ($Level) {
      'Verbose' { "`e[32m" } # Green
      'Info' { "`e[34m" } # Blue
      'Warning' { "`e[33m" } # Yellow
      'Error' { "`e[31m" } # Red
      Default { "`e[39m" } # Default
    }

    if ($Identifier -and $Identifier.Where({ -not [string]::IsNullOrEmpty($_) }, 'First')) {
      $MergedIdentifier = $Identifier.Where({ -not [string]::IsNullOrEmpty($_) }).ForEach({ "[${_}]" }) -join ''
      Write-Host -Object "${Color}`e[1m${MergedIdentifier}`e[22m ${Object}`e[0m"
    } else {
      Write-Host -Object "${Color}${Object}`e[0m"
    }
  }
}

# Set up Write-Log identifier
$Script:DumplingsLogIdentifier = @('Dumplings')

if (-not $Parallel) {
  # Load environmental variables from the .env file without overriding existing ones
  $Private:DotEnvPath = Join-Path $PWD '.env'
  if (Test-Path -LiteralPath $Private:DotEnvPath -PathType Leaf) {
    foreach ($DotEnvLine in (Get-Content -LiteralPath $Private:DotEnvPath)) {
      if ($DotEnvLine -cnotmatch '^\s*(?:export\s+)?(?<Name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<Value>.*)$') { continue }

      $DotEnvName = $Matches.Name
      if (Test-Path -LiteralPath "Env:${DotEnvName}") { continue }

      $DotEnvValue = $Matches.Value.Trim()
      if ($DotEnvValue.Length -ge 2 -and (($DotEnvValue.StartsWith("'") -and $DotEnvValue.EndsWith("'")) -or ($DotEnvValue.StartsWith('"') -and $DotEnvValue.EndsWith('"')))) {
        $DotEnvValue = $DotEnvValue.Substring(1, $DotEnvValue.Length - 2)
      } else {
        $DotEnvValue = ($DotEnvValue -split '\s+#', 2)[0].TrimEnd()
      }
      Set-Item -LiteralPath "Env:${DotEnvName}" -Value $DotEnvValue
    }
  }

  # Set console input and output encoding to UTF-8. This will also affect sub-threads
  $Private:OldOutputEncoding = [System.Console]::OutputEncoding
  $Private:OldInputEncoding = [System.Console]::InputEncoding
  [System.Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(65001)
  [System.Console]::InputEncoding = [System.Text.Encoding]::GetEncoding(65001)

  # Remove old jobs to avoid conflicts
  Get-Job | Where-Object -FilterScript { $_.Name.StartsWith('Dumplings') } | Remove-Job -Force

  # Install necessary module
  @('powershell-yaml') | ForEach-Object -Process {
    if (-not (Get-Module -Name $_ -ListAvailable)) {
      Write-Log -Object "Installing PowerShell module: ${_}"
      $null = Install-Module -Name $_ -Force -ErrorAction Stop
      Write-Log -Object "The PowerShell module ${_} has been installed"
    }
  }

  # Load preferences from the preference file
  $Global:DumplingsPreference = $null
  $Private:DumplingsPreferencePath = Join-Path $PWD 'Preference.yaml'
  if (Test-Path -Path $Private:DumplingsPreferencePath) {
    try {
      $Global:DumplingsPreference = Get-Content -Path $Private:DumplingsPreferencePath -Raw | ConvertFrom-Yaml -Ordered
    } catch {
      Write-Log -Object "Failed to load preferences. Assigning an empty hashtable: ${_}" -Level Warning
    }
  }
  # ConvertFrom-Yaml will return $null if the file exists but its content is empty. Assign an empty hashtable if that occurred
  if (-not $Global:DumplingsPreference) {
    $Global:DumplingsPreference = [ordered]@{}
  }
  # Then load preferences from parameters. They have higher priority so the existing ones of the same names will be overrided
  if ($Params -and $Params -is [System.Collections.IEnumerable]) {
    $LastKey = $null
    foreach ($Item in $Params) {
      if ($Item -cmatch '^-') {
        $LastKey = $Item -creplace '^-'
        $Global:DumplingsPreference[$LastKey] = $true
      } else {
        $Global:DumplingsPreference[$LastKey] = $Item
      }
    }
  }

  # Load secrets from the environmental variable
  $Global:DumplingsSecret = $null
  if (Test-Path -Path Env:\DUMPLINGS_SECRET) {
    try {
      $Global:DumplingsSecret = $Env:DUMPLINGS_SECRET | ConvertFrom-Yaml -Ordered
    } catch {
      Write-Log -Object "Failed to load secrets. Assigning an empty hashtable: ${_}" -Level Warning
    }
  }
  # ConvertFrom-Yaml will return $null if the environmental variable exists but its value is empty. Assign an empty hashtable if that occurred
  if (-not $Global:DumplingsSecret) {
    $Global:DumplingsSecret = [ordered]@{}
  }
  # Then load secrets from the secret file. They have higher priority so the existing ones of the same names will be overrided
  $Private:DumplingsSecretPath = Join-Path $PWD 'Secret.yaml'
  if (Test-Path -Path $Private:DumplingsSecretPath) {
    try {
      $Secret = Get-Content -Path $Private:DumplingsSecretPath -Raw | ConvertFrom-Yaml -Ordered
      if ($Secret -and $Secret -is [System.Collections.IDictionary]) {
        $Secret.GetEnumerator() | ForEach-Object -Process { $Global:DumplingsSecret[$_.Key] = $_.Value }
      }
    } catch {
      Write-Log -Object "Failed to load secrets. Assigning an empty hashtable: ${_}" -Level Warning
    }
  }

  # Load default parameter values from the preferences
  $Global:DumplingsDefaultParameterValues = $null
  if ($Global:DumplingsPreference.Contains('DefaultParameterValues')) {
    try {
      $Global:DumplingsDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]$Global:DumplingsPreference.DefaultParameterValues
      if ($Global:DumplingsDefaultParameterValues) { $PSDefaultParameterValues = $Global:DumplingsDefaultParameterValues }
    } catch {
      Write-Log -Object "Failed to load default parameter values: ${_}" -Level Warning
    }
  }

  # Install specified PowerShell modules
  if ($Global:DumplingsPreference.Contains('PowerShellModules') -and $Global:DumplingsPreference.PowerShellModules -is [System.Collections.IEnumerable]) {
    $Global:DumplingsPreference.PowerShellModules | ForEach-Object -Process {
      if (-not (Get-Module -Name $_ -ListAvailable)) {
        Write-Log -Object "Installing PowerShell module: ${_}"
        $null = Install-Module -Name $_ -Force -ErrorAction Stop
        Write-Log -Object "The PowerShell module ${_} has been installed"
      }
    }
  }

  # Queue the tasks to load
  if (-not (Test-Path -Path $Path)) {
    throw "The task directory `"${Path}`" does not exist. Please check the path or specify another one."
  }
  [string[]]$SelectedTaskNames = $Name ?
  @($Name | ForEach-Object -Process { Join-Path $Path $_ 'Config.yaml' } | Get-ChildItem -File | Select-Object -ExpandProperty Directory | Select-Object -ExpandProperty Name) :
  @(Join-Path $Path '*' 'Config.yaml' | Get-ChildItem -File | Select-Object -ExpandProperty Directory | Select-Object -ExpandProperty Name)

  $TaskDependencyPlan = Resolve-DumplingsTaskDependency -TaskDirectory $Path -TaskName $SelectedTaskNames
  $TaskDependencies = $TaskDependencyPlan.Dependencies
  [System.Collections.Concurrent.ConcurrentQueue[string]]$TaskNames = $TaskDependencyPlan.TaskNames
  $TaskNamesTotalCount = $TaskNames.Count
  $DependencyTaskCount = $TaskNamesTotalCount - @($SelectedTaskNames | Sort-Object -Unique).Count
  Write-Log -Object "${TaskNamesTotalCount} task(s) found (${DependencyTaskCount} automatic dependency task(s))"

  # Set up thread-safe shared storage, task completion signals, and worker diagnostics across sub-threads.
  $Global:DumplingsStorage = [hashtable]::Synchronized(@{})
  $TaskStates = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $TaskSignals = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.ManualResetEventSlim]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $WokTaskTracker = Open-DumplingsWokTaskTracker
  foreach ($PlannedTaskName in $TaskDependencyPlan.TaskNames) {
    $TaskStates[$PlannedTaskName] = 'Pending'
    $TaskSignals[$PlannedTaskName] = [System.Threading.ManualResetEventSlim]::new($false)
  }

  # Set up temp folder for tasks
  $Global:DumplingsCache = (New-Item -Path ([System.IO.Path]::GetTempPath()) -Name "Dumplings-$(Get-Random)" -ItemType Directory -Force).FullName

  # Set up output folder for tasks
  $Global:DumplingsOutput = (New-Item -Path $PWD -Name 'Outputs' -ItemType Directory -Force).FullName
  Get-ChildItem $Global:DumplingsOutput | Remove-Item -Recurse -Force -ProgressAction 'SilentlyContinue'

  # Switch to multi-threads mode if the number of threads is set to be greater than 1, otherwise stay in single-thread mode
  if ($ThrottleLimit -gt 1) {
    # The default number of maximum concurrent threads of ThreadJob is 5. Run Start-ThreadJob once to increase the throttle limit
    # Add the value by 5 to allow the tasks to run ThreadJob immediately instead of waiting for the sub-threads exiting
    $null = Start-ThreadJob -ScriptBlock {} -ThrottleLimit ($ThrottleLimit + 5) | Wait-Job

    Write-Log -Object "Starting ${ThrottleLimit} thread jobs"

    # Re-run this script in sub-threads
    $Jobs = 0..($ThrottleLimit - 1) | ForEach-Object -Process {
      Start-ThreadJob -FilePath $MyInvocation.MyCommand.Definition -Name "DumplingsWok${_}" -StreamingHost $Host -ArgumentList @($Name, $Path, $PassThru, $ThrottleLimit, $true, $_, $Params)
    }
  }
}

# In single-thread mode, run tasks in the main thread directly
# In multi-threads mode, run tasks in sub-threads, and the main thread will skip this region
if ($Parallel -or $ThrottleLimit -eq 1) {
  # Set up parameters
  $Global:DumplingsRoot = $Parallel ? $using:PWD : $PWD
  # Set up a shared hashtable within each sub-thread
  $Global:DumplingsSessionStorage = [ordered]@{}
  # Set up Write-Log identifier
  $WokName = "DumplingsWok${WokID}"
  $Script:DumplingsLogIdentifier = @($WokName)
  # If in sub-threads, get the shared variables from the main thread
  if ($Parallel) {
    $TaskNames = $using:TaskNames
    $TaskNamesTotalCount = $using:TaskNamesTotalCount
    $TaskDependencies = $using:TaskDependencies
    $TaskStates = $using:TaskStates
    $TaskSignals = $using:TaskSignals
    $WokTaskTracker = $using:WokTaskTracker
    $Global:DumplingsPreference = $using:DumplingsPreference
    $Global:DumplingsSecret = $using:DumplingsSecret
    $Global:DumplingsDefaultParameterValues = $using:DumplingsDefaultParameterValues
    $Global:DumplingsStorage = $using:DumplingsStorage
    $Global:DumplingsCache = $using:DumplingsCache
    $Global:DumplingsOutput = $using:DumplingsOutput
  }

  # Apply default parameter values
  if ($Global:DumplingsDefaultParameterValues) { $PSDefaultParameterValues = $Global:DumplingsDefaultParameterValues }

  # Import modules
  $Private:ModulePath = Join-Path $Global:DumplingsRoot 'Modules'
  if (Test-Path -Path $ModulePath) {
    Join-Path $Private:ModulePath '*' 'Index.ps1' | Get-ChildItem -File | ForEach-Object -Process { . $_ }
  }

  # Build and run tasks
  $TaskName = [string]$null
  while ($TaskNames.TryDequeue([ref]$TaskName)) {
    # Progress records can be dropped or delayed. Keep authoritative timeout evidence in shared memory instead.
    Write-DumplingsWokTask -Tracker $WokTaskTracker -WokName $WokName -TaskName $TaskName

    # Print a progress bar with a perecentage and the name of the current task
    Write-Progress -Id 0 -Activity 'Dumplings' -PercentComplete (100 - $TaskNames.Count / $TaskNamesTotalCount * 100) -CurrentOperation $TaskName -Status "$($TaskNamesTotalCount - $TaskNames.Count)/$($TaskNamesTotalCount) $TaskName"

    $Task = $null
    try {
      # Wait until every shared-data provider has reached a terminal state.
      foreach ($DependencyName in $TaskDependencies[$TaskName]) {
        $TaskSignals[$DependencyName].Wait()
      }

      $FailedDependencies = @($TaskDependencies[$TaskName] | Where-Object { $TaskStates[$_] -ne 'Succeeded' })
      if ($FailedDependencies.Count -gt 0) {
        $TaskStates[$TaskName] = 'Blocked'
        Write-Log -Object "Skipped task ${TaskName} because dependency task(s) did not succeed: $($FailedDependencies -join ', ')" -Level Warning
      } else {
        $TaskStates[$TaskName] = 'Running'

        # Build task
        try {
          $TaskPath = Join-Path $Path $TaskName -Resolve
          $TaskConfig = Join-Path $TaskPath 'Config.yaml' -Resolve | Get-Item | Get-Content -Raw | ConvertFrom-Yaml -Ordered
          $Task = New-Object -TypeName $TaskConfig.Type -ArgumentList @{
            Name   = $TaskName
            Path   = $TaskPath
            Config = $TaskConfig
          }
        } catch {
          Write-Log -Object "Failed to initialize the task ${TaskName}:" -Level Error
          $_ | Out-Host
        }

        if ($Task) {
          Write-Progress -Id ($WokID + 1) -ParentId 0 -Activity "DumplingsWok${WokID}" -CurrentOperation $TaskName -Status $TaskName

          # Run task
          try {
            $Task.Invoke()
          } catch {
            Write-Log -Object "An error occured in the task ${TaskName}:" -Level Error
            $_ | Out-Host
          }

          if ($Task.InvocationSucceeded) {
            $TaskStates[$TaskName] = 'Succeeded'
          } elseif ($Task.InvocationSkipped) {
            $TaskStates[$TaskName] = 'Skipped'
          } else {
            $TaskStates[$TaskName] = 'Failed'
          }
        } else {
          $TaskStates[$TaskName] = 'Failed'
        }
      }
    } finally {
      $TaskSignals[$TaskName].Set()

      if ($Task) {
        # Pass the task objects to output if enabled
        if ($PassThru) {
          Write-Output -InputObject $Task
        } else {
          $Task.Dispose()
        }
      }
    }
  }

  Write-Log -Object 'Done' -Level Verbose

  # Clean the environment for the sub-thread
  Get-Module | Where-Object -FilterScript { $_.Path.Contains($Global:DumplingsRoot) -and -not $_.Name.Contains('oh-my-posh') } | Remove-Module
}

# Set up Write-Log identifier
$Script:DumplingsLogIdentifier = @('Dumplings')

if (-not $Parallel) {
  # In multi-threads mode, let the main thread wait for all sub-threads first
  if ($ThrottleLimit -gt 1) {
    # Read the timeout from the preference or use the default value - 50 minutes
    $NewTimeout = [int]$null
    $Timeout = $Global:DumplingsPreference.Contains('Timeout') -and [int]::TryParse($Global:DumplingsPreference.Timeout, [ref]$NewTimeout) ? $NewTimeout : 3000

    # Wait for all threads with the specified timeout
    $null = $Jobs | Wait-Job -Timeout $Timeout

    # Check failed sub-threads
    if ($Jobs.State -eq 'Failed') {
      $Jobs | Where-Object -Property 'State' -EQ -Value 'Failed' | ForEach-Object -Process {
        Write-Log -Object "An error occurred in the sub-thread $($_.Name):" -Level Error
        $_.JobStateInfo.Reason.ErrorRecord | Out-Host
      }
    }

    # Snapshot running sub-threads and their last dequeued tasks before force-removing the jobs.
    $RunningJobs = @($Jobs | Where-Object -Property 'State' -EQ -Value 'Running')
    if ($RunningJobs.Count -gt 0) {
      Write-Log -Object "The following sub-threads exceeds the time limit of ${Timeout} second(s) and will be stopped forcibly:" -Level Warning
      foreach ($Job in $RunningJobs) {
        $LastTaskName = Read-DumplingsWokTask -Tracker $WokTaskTracker -WokName $Job.Name
        if (-not [string]::IsNullOrWhiteSpace($LastTaskName)) {
          Write-Log -Object "$($Job.Name): ${LastTaskName}" -Level Warning
        } else {
          Write-Log -Object "$($Job.Name): No task was dequeued before the worker stopped" -Level Warning
        }
      }
      Write-Progress -Id 0 -Activity 'Dumplings' -Completed -Status 'Stopped'
    } else {
      Write-Progress -Id 0 -Activity 'Dumplings' -Completed -Status 'Completed'
    }

    # Pass the task objects to output if enabled
    if ($PassThru) { $Jobs | Receive-Job }

    # Force remove the jobs
    $Jobs | Remove-Job -Force
  }

  # Clean and restore the environment for the main thread
  [System.Console]::OutputEncoding = $Private:OldOutputEncoding
  [System.Console]::InputEncoding = $Private:OldInputEncoding
  foreach ($TaskSignal in $TaskSignals.Values) { $TaskSignal.Dispose() }
  Remove-Item -Path $Global:DumplingsCache -Recurse -Force -ErrorAction 'Continue' -ProgressAction 'SilentlyContinue'
  Set-StrictMode -Off
}
