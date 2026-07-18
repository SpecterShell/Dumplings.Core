# SPDX-License-Identifier: MIT
# Scoped synchronization helpers used by the Dumplings runner and task scripts.

function Use-Mutex {
  <#
  .SYNOPSIS
    Execute a script block while owning a mutex.
  .PARAMETER Name
    The name of a mutex to open or create. Named mutexes can coordinate other processes.
  .PARAMETER Mutex
    An existing mutex owned and disposed by the caller.
  .PARAMETER ScriptBlock
    The operation to execute while the mutex is held.
  .PARAMETER TimeoutMilliseconds
    The maximum time to wait for the mutex, or -1 to wait indefinitely.
  .OUTPUTS
    The unchanged pipeline output produced by ScriptBlock.
  #>
  [CmdletBinding(DefaultParameterSetName = 'Name')]
  param (
    [Parameter(Mandatory, ParameterSetName = 'Name')]
    [ValidateNotNullOrWhiteSpace()]
    [string]$Name,

    [Parameter(Mandatory, ParameterSetName = 'Object')]
    [ValidateNotNull()]
    [System.Threading.Mutex]$Mutex,

    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNull()]
    [scriptblock]$ScriptBlock,

    [Parameter()]
    [ValidateRange(-1, [int]::MaxValue)]
    [int]$TimeoutMilliseconds = [System.Threading.Timeout]::Infinite
  )

  $OwnsMutexObject = $PSCmdlet.ParameterSetName -ceq 'Name'
  if ($OwnsMutexObject) { $Mutex = [System.Threading.Mutex]::new($false, $Name) }

  $Acquired = $false
  try {
    try {
      $Acquired = $Mutex.WaitOne($TimeoutMilliseconds)
    } catch [System.Threading.AbandonedMutexException] {
      # An abandoned mutex is granted to this thread despite the exception.
      $Acquired = $true
    }

    if (-not $Acquired) {
      $Description = $OwnsMutexObject ? "mutex '${Name}'" : 'the supplied mutex'
      throw [System.TimeoutException]::new("Timed out waiting for ${Description} after ${TimeoutMilliseconds} ms.")
    }

    & $ScriptBlock
  } finally {
    if ($Acquired) { $Mutex.ReleaseMutex() }
    if ($OwnsMutexObject) { $Mutex.Dispose() }
  }
}

function Use-Semaphore {
  <#
  .SYNOPSIS
    Execute a script block while holding one slot from a semaphore.
  .PARAMETER Semaphore
    An existing Semaphore or SemaphoreSlim owned and disposed by the caller.
  .PARAMETER ScriptBlock
    The operation to execute while the semaphore slot is held.
  .PARAMETER TimeoutMilliseconds
    The maximum time to wait for a slot, or -1 to wait indefinitely.
  .OUTPUTS
    The unchanged pipeline output produced by ScriptBlock.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateScript({ $_ -is [System.Threading.Semaphore] -or $_ -is [System.Threading.SemaphoreSlim] })]
    [object]$Semaphore,

    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNull()]
    [scriptblock]$ScriptBlock,

    [Parameter()]
    [ValidateRange(-1, [int]::MaxValue)]
    [int]$TimeoutMilliseconds = [System.Threading.Timeout]::Infinite
  )

  $Acquired = $Semaphore -is [System.Threading.SemaphoreSlim] ?
  $Semaphore.Wait($TimeoutMilliseconds) :
  $Semaphore.WaitOne($TimeoutMilliseconds)
  if (-not $Acquired) {
    throw [System.TimeoutException]::new("Timed out waiting for the supplied semaphore after ${TimeoutMilliseconds} ms.")
  }

  try {
    & $ScriptBlock
  } finally {
    $null = $Semaphore.Release()
  }
}

function Use-Monitor {
  <#
  .SYNOPSIS
    Execute a script block while holding the monitor for an object.
  .PARAMETER InputObject
    The reference object whose monitor should be acquired.
  .PARAMETER ScriptBlock
    The operation to execute while the monitor is held.
  .PARAMETER TimeoutMilliseconds
    The maximum time to wait for the monitor, or -1 to wait indefinitely.
  .OUTPUTS
    The unchanged pipeline output produced by ScriptBlock.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$InputObject,

    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNull()]
    [scriptblock]$ScriptBlock,

    [Parameter()]
    [ValidateRange(-1, [int]::MaxValue)]
    [int]$TimeoutMilliseconds = [System.Threading.Timeout]::Infinite
  )

  $Acquired = [System.Threading.Monitor]::TryEnter($InputObject, $TimeoutMilliseconds)
  if (-not $Acquired) {
    throw [System.TimeoutException]::new("Timed out waiting for the supplied object's monitor after ${TimeoutMilliseconds} ms.")
  }

  try {
    & $ScriptBlock
  } finally {
    [System.Threading.Monitor]::Exit($InputObject)
  }
}

Export-ModuleMember -Function Use-Mutex, Use-Semaphore, Use-Monitor
