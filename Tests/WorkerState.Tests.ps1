BeforeAll {
  Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Libraries', 'WorkerState.psm1') -Force
}

Describe 'Dumplings worker task tracking' {
  It 'returns the latest task recorded for each worker' {
    $Tracker = Open-DumplingsWokTaskTracker

    Write-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok0' -TaskName 'First.Task'
    Write-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok1' -TaskName 'Other.Task'
    Write-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok0' -TaskName 'Latest.Task'

    Read-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok0' | Should -BeExactly 'Latest.Task'
    Read-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok1' | Should -BeExactly 'Other.Task'
  }

  It 'returns no value when a worker did not dequeue a task' {
    $Tracker = Open-DumplingsWokTaskTracker

    Read-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok0' | Should -BeNullOrEmpty
  }

  It 'retains the last task after a worker is forcibly stopped' {
    $Tracker = Open-DumplingsWokTaskTracker
    $Job = Start-ThreadJob -ScriptBlock {
      $SharedTracker = $using:Tracker
      $SharedTracker['DumplingsWok0'] = 'TimedOut.Task'
      while ($true) { Start-Sleep -Milliseconds 100 }
    }

    try {
      $Deadline = [DateTime]::UtcNow.AddSeconds(5)
      while (-not $Tracker.ContainsKey('DumplingsWok0') -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 20
      }
      $Tracker.ContainsKey('DumplingsWok0') | Should -BeTrue

      $Job | Stop-Job

      Read-DumplingsWokTask -Tracker $Tracker -WokName 'DumplingsWok0' | Should -BeExactly 'TimedOut.Task'
    } finally {
      $Job | Remove-Job -Force -ErrorAction SilentlyContinue
    }
  }
}
