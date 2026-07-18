BeforeAll {
  $Script:SynchronizationModulePath = Join-Path $PSScriptRoot '..' 'Libraries' 'Synchronization.psm1'
  Import-Module $Script:SynchronizationModulePath -Force
}

Describe 'Dumplings synchronization helpers' {
  It 'preserves script-block output while owning a mutex' {
    @(Use-Mutex -Name "Dumplings-SynchronizationTest-$([guid]::NewGuid().ToString('N'))" -ScriptBlock {
        'first'
        2
      }) | Should -Be @('first', 2)
  }

  It 'releases a caller-owned mutex when the script block throws' {
    $Mutex = [Threading.Mutex]::new()
    try {
      { Use-Mutex -Mutex $Mutex -ScriptBlock { throw 'synthetic failure' } } | Should -Throw '*synthetic failure*'
      $Mutex.WaitOne(0) | Should -BeTrue
      $Mutex.ReleaseMutex()
    } finally {
      $Mutex.Dispose()
    }
  }

  It 'times out while another runspace owns the mutex' {
    $Mutex = [Threading.Mutex]::new()
    $Entered = [Threading.ManualResetEventSlim]::new($false)
    $Release = [Threading.ManualResetEventSlim]::new($false)
    $Job = Start-ThreadJob -ArgumentList $Script:SynchronizationModulePath, $Mutex, $Entered, $Release -ScriptBlock {
      param($ModulePath, $SharedMutex, $EnteredSignal, $ReleaseSignal)
      Import-Module $ModulePath -Force
      Use-Mutex -Mutex $SharedMutex -ScriptBlock {
        $EnteredSignal.Set()
        $ReleaseSignal.Wait()
      }
    }

    try {
      $Entered.Wait(5000) | Should -BeTrue
      { Use-Mutex -Mutex $Mutex -TimeoutMilliseconds 50 -ScriptBlock { 'must not run' } } |
        Should -Throw '*Timed out waiting*'
    } finally {
      $Release.Set()
      $Job | Wait-Job -Timeout 5 | Out-Null
      $Job | Remove-Job -Force -ErrorAction SilentlyContinue
      $Entered.Dispose()
      $Release.Dispose()
      $Mutex.Dispose()
    }
  }

  It 'coordinates a named mutex with another PowerShell process' {
    $MutexName = "Local\Dumplings-SynchronizationProcessTest-$([guid]::NewGuid().ToString('N'))"
    $ReadyPath = Join-Path $TestDrive 'process-ready'
    $ReleasePath = Join-Path $TestDrive 'process-release'
    $ChildScriptPath = Join-Path $TestDrive 'Hold-Mutex.ps1'
    Set-Content -LiteralPath $ChildScriptPath -Value @'
param($MutexName, $ReadyPath, $ReleasePath)
$Mutex = [Threading.Mutex]::new($false, $MutexName)
try {
  $null = $Mutex.WaitOne()
  [IO.File]::WriteAllText($ReadyPath, 'ready')
  while (-not [IO.File]::Exists($ReleasePath)) { Start-Sleep -Milliseconds 20 }
} finally {
  $Mutex.ReleaseMutex()
  $Mutex.Dispose()
}
'@
    $Process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
      '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ChildScriptPath,
      $MutexName, $ReadyPath, $ReleasePath
    ) -PassThru -WindowStyle Hidden

    try {
      $Ready = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath $ReadyPath) -and $Ready.ElapsedMilliseconds -lt 5000) {
        Start-Sleep -Milliseconds 20
      }
      Test-Path -LiteralPath $ReadyPath | Should -BeTrue
      { Use-Mutex -Name $MutexName -TimeoutMilliseconds 50 -ScriptBlock { 'must not run' } } |
        Should -Throw '*Timed out waiting*'
    } finally {
      Set-Content -LiteralPath $ReleasePath -Value 'release'
      if (-not $Process.WaitForExit(5000)) { $Process.Kill($true) }
      $Process.Dispose()
    }
  }

  It 'accepts ownership of an abandoned mutex' {
    $Mutex = [Threading.Mutex]::new()
    $Entered = [Threading.ManualResetEventSlim]::new($false)
    $Job = Start-ThreadJob -ArgumentList $Mutex, $Entered -ScriptBlock {
      param($SharedMutex, $EnteredSignal)
      $null = $SharedMutex.WaitOne()
      $EnteredSignal.Set()
    }

    try {
      $Entered.Wait(5000) | Should -BeTrue
      $Job | Wait-Job -Timeout 5 | Should -HaveCount 1
      Use-Mutex -Mutex $Mutex -TimeoutMilliseconds 1000 -ScriptBlock { 'recovered' } |
        Should -BeExactly 'recovered'
    } finally {
      $Job | Remove-Job -Force -ErrorAction SilentlyContinue
      $Entered.Dispose()
      $Mutex.Dispose()
    }
  }

  It 'releases semaphore slots after success and failure' {
    $Semaphore = [Threading.SemaphoreSlim]::new(1, 1)
    try {
      Use-Semaphore -Semaphore $Semaphore -ScriptBlock { 'success' } | Should -BeExactly 'success'
      $Semaphore.CurrentCount | Should -Be 1

      { Use-Semaphore -Semaphore $Semaphore -ScriptBlock { throw 'synthetic failure' } } | Should -Throw
      $Semaphore.CurrentCount | Should -Be 1
    } finally {
      $Semaphore.Dispose()
    }
  }

  It 'releases a monitor after success and failure' {
    $Gate = [object]::new()
    Use-Monitor -InputObject $Gate -ScriptBlock { 'success' } | Should -BeExactly 'success'
    { Use-Monitor -InputObject $Gate -ScriptBlock { throw 'synthetic failure' } } | Should -Throw

    [Threading.Monitor]::TryEnter($Gate, 0) | Should -BeTrue
    [Threading.Monitor]::Exit($Gate)
  }

  It 'does not allow raw mutex construction in task scripts' {
    $TaskRoot = Join-Path $PSScriptRoot '..' '..' 'Tasks'
    $Violations = Get-ChildItem -LiteralPath $TaskRoot -Filter '*.ps1' -File -Recurse |
      Select-String -Pattern '(?:System\.)?Threading\.Mutex|System\.Threading\.Mutex'

    $Violations | Should -BeNullOrEmpty
  }
}
