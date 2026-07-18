# Track the last task dequeued by each Dumplings worker independently of PowerShell progress records.

function Open-DumplingsWokTaskTracker {
  <#
  .SYNOPSIS
    Create thread-safe storage for the last task dequeued by each worker
  #>
  [OutputType([System.Collections.Concurrent.ConcurrentDictionary[string, string]])]
  param ()

  return [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new([System.StringComparer]::Ordinal)
}

function Write-DumplingsWokTask {
  <#
  .SYNOPSIS
    Record the last task dequeued by a worker
  #>
  param (
    [Parameter(Mandatory)]
    [System.Collections.Concurrent.ConcurrentDictionary[string, string]]$Tracker,

    [Parameter(Mandatory)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$WokName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$TaskName
  )

  $Tracker[$WokName] = $TaskName
}

function Read-DumplingsWokTask {
  <#
  .SYNOPSIS
    Read the last task dequeued by a worker
  #>
  [OutputType([string])]
  param (
    [Parameter(Mandatory)]
    [System.Collections.Concurrent.ConcurrentDictionary[string, string]]$Tracker,

    [Parameter(Mandatory)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$WokName
  )

  $TaskName = [string]::Empty
  if ($Tracker.TryGetValue($WokName, [ref]$TaskName)) {
    return $TaskName
  }
}

Export-ModuleMember -Function Open-DumplingsWokTaskTracker, Write-DumplingsWokTask, Read-DumplingsWokTask
