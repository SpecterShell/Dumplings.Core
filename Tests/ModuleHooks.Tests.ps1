BeforeAll {
  $Script:ModulePath = Join-Path $PSScriptRoot '..' 'Libraries' 'ModuleHooks.psm1'
  Import-Module $Script:ModulePath -Force

  function New-TestModuleHook {
    param (
      [Parameter(Mandatory)][string]$Root,
      [Parameter(Mandatory)][string]$ModuleName,
      [Parameter(Mandatory)][string]$HookName,
      [Parameter(Mandatory)][string]$Content
    )

    $HookDirectory = Join-Path $Root $ModuleName 'Hooks'
    $null = New-Item -Path $HookDirectory -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $HookDirectory "${HookName}.ps1") -Value $Content
  }
}

Describe 'Dumplings module lifecycle hooks' {
  BeforeEach {
    $Script:HookRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $Script:HookRoot -ItemType Directory
  }

  It 'discovers exact hook filenames in deterministic module order' {
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Zeta -HookName BeforeTask -Content 'param($Context)'
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Alpha -HookName BeforeTask -Content 'param($Context)'
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Alpha -HookName Helper -Content 'throw "must not run"'

    $Plan = Get-DumplingsModuleHookPlan -ModulePath $Script:HookRoot

    @($Plan.Hooks.BeforeTask | ForEach-Object { Split-Path (Split-Path $_ -Parent) -Parent | Split-Path -Leaf }) |
      Should -Be @('Alpha', 'Zeta')
    @($Plan.Hooks.Values | ForEach-Object { $_ } | Where-Object { $_ -like '*Helper.ps1' }) | Should -BeNullOrEmpty
  }

  It 'runs before hooks forward against one mutable context' {
    $Content = 'param($Context); $Context.Items.Order.Add((Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf)); $Context.Count++'
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Zeta -HookName BeforeTask -Content $Content
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Alpha -HookName BeforeTask -Content $Content
    $Plan = Get-DumplingsModuleHookPlan -ModulePath $Script:HookRoot
    $Context = [ordered]@{ Items = @{ Order = [Collections.Generic.List[string]]::new() }; Count = 0; HookName = $null; HookPath = $null }

    Invoke-DumplingsModuleHook -Plan $Plan -Name BeforeTask -Context $Context

    $Context.Items.Order.ToArray() | Should -Be @('Alpha', 'Zeta')
    $Context.Count | Should -Be 2
  }

  It 'fails fast for a before hook' {
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Alpha -HookName BeforeTask -Content 'param($Context); $Context.Items.Order.Add("Alpha"); throw "alpha failed"'
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Zeta -HookName BeforeTask -Content 'param($Context); $Context.Items.Order.Add("Zeta")'
    $Plan = Get-DumplingsModuleHookPlan -ModulePath $Script:HookRoot
    $Context = [ordered]@{ Items = @{ Order = [Collections.Generic.List[string]]::new() }; HookName = $null; HookPath = $null }

    { Invoke-DumplingsModuleHook -Plan $Plan -Name BeforeTask -Context $Context } | Should -Throw '*alpha failed*'
    $Context.Items.Order.ToArray() | Should -Be @('Alpha')
  }

  It 'runs every cleanup hook in reverse order before throwing aggregated failures' {
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Alpha -HookName AfterTask -Content 'param($Context); $Context.Items.Order.Add("Alpha"); throw "alpha failed"'
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Zeta -HookName AfterTask -Content 'param($Context); $Context.Items.Order.Add("Zeta"); throw "zeta failed"'
    $Plan = Get-DumplingsModuleHookPlan -ModulePath $Script:HookRoot
    $Context = [ordered]@{ Items = @{ Order = [Collections.Generic.List[string]]::new() }; HookName = $null; HookPath = $null }

    { Invoke-DumplingsModuleHook -Plan $Plan -Name AfterTask -Context $Context } | Should -Throw '*one or more*AfterTask*'
    $Context.Items.Order.ToArray() | Should -Be @('Zeta', 'Alpha')
  }

  It 'passes a path-only hook plan into a thread-job runspace' {
    New-TestModuleHook -Root $Script:HookRoot -ModuleName Alpha -HookName WorkerStarting -Content 'param($Context); $Context.Items.Value = "worker-hook"'
    $Plan = Get-DumplingsModuleHookPlan -ModulePath $Script:HookRoot
    $Job = Start-ThreadJob -ArgumentList $Script:ModulePath, $Plan -ScriptBlock {
      param($HookModule, $HookPlan)
      Import-Module $HookModule -Force
      $Context = [ordered]@{ Items = @{}; HookName = $null; HookPath = $null }
      Invoke-DumplingsModuleHook -Plan $HookPlan -Name WorkerStarting -Context $Context
      $Context.Items.Value
    }

    try {
      $Job | Wait-Job -Timeout 10 | Should -HaveCount 1
      $Job | Receive-Job -ErrorAction Stop | Should -BeExactly 'worker-hook'
    } finally {
      $Job | Remove-Job -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps the Core runner independent of module-specific WebDriver behavior' {
    $Runner = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'Index.ps1') -Raw

    $Runner | Should -Not -Match 'WebDriver|__DumplingsWebDriverLeasePool'
    $Runner | Should -Match 'Invoke-DumplingsModuleHook.+BeforeTask'
    $Runner | Should -Match 'Invoke-DumplingsModuleHook.+AfterTask'
    $Runner.IndexOf('ModuleHooks\Invoke-DumplingsModuleHook -Plan $DumplingsModuleHookPlan -Name BeforeForcedWorkerStop') |
      Should -BeLessThan $Runner.IndexOf('$Jobs | Remove-Job -Force')
  }
}
