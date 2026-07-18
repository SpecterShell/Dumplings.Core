BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '..' 'Libraries' 'TaskDependency.psm1') -Force

  function New-TestTask {
    param (
      [Parameter(Mandatory)][string]$Root,
      [Parameter(Mandatory)][string]$Name,
      [Parameter(Mandatory)][string]$Script,
      [AllowNull()][object]$DependsOn
    )

    $TaskPath = New-Item -Path $Root -Name $Name -ItemType Directory -Force
    $Config = [System.Collections.Generic.List[string]]@('Type: SimpleTask')
    if ($PSBoundParameters.ContainsKey('DependsOn')) {
      if ($DependsOn -is [string]) {
        $Config.Add("DependsOn: `"${DependsOn}`"")
      } else {
        $Config.Add('DependsOn:')
        foreach ($Dependency in $DependsOn) {
          $Config.Add("- `"${Dependency}`"")
        }
      }
    }
    Set-Content -LiteralPath (Join-Path $TaskPath 'Config.yaml') -Value $Config
    Set-Content -LiteralPath (Join-Path $TaskPath 'Script.ps1') -Value $Script
  }
}

Describe 'Get-DumplingsTaskStorageKey' {
  It 'reads literal property and index keys and ignores dynamic indexes' {
    $ScriptPath = Join-Path $TestDrive 'Storage.ps1'
    Set-Content -LiteralPath $ScriptPath -Value @'
$Global:DumplingsStorage.PropertyKey = 1
$Value = $Global:DumplingsStorage['IndexKey']
$Dynamic = $Global:DumplingsStorage[$Key]
'@

    @(Get-DumplingsTaskStorageKey -Path $ScriptPath) | Should -Be @('IndexKey', 'PropertyKey')
    @(Get-DumplingsTaskStorageKey -Path $ScriptPath -Access Write) | Should -Be @('PropertyKey')
  }
}

Describe 'Resolve-DumplingsTaskDependency' {
  BeforeEach {
    $TaskRoot = New-Item -Path $TestDrive -Name ([guid]::NewGuid().ToString()) -ItemType Directory
  }

  It 'includes an explicitly declared scalar dependency' {
    New-TestTask -Root $TaskRoot -Name '#Shared' -Script '$Global:DumplingsStorage.Shared = 1'
    New-TestTask -Root $TaskRoot -Name '#Unrelated' -Script '$Global:DumplingsStorage.Unrelated = 1'
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = $Global:DumplingsStorage.Shared' -DependsOn '#Shared'

    $Plan = Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package'

    $Plan.TaskNames | Should -Be @('#Shared', 'Vendor.Package')
    $Plan.Dependencies['Vendor.Package'] | Should -Be @('#Shared')
  }

  It 'supports arrays of ordinary task dependencies' {
    New-TestTask -Root $TaskRoot -Name 'Prepare.First' -Script '$Value = 1'
    New-TestTask -Root $TaskRoot -Name 'Prepare.Second' -Script '$Value = 2'
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = 3' -DependsOn @('Prepare.First', 'Prepare.Second')

    $Plan = Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package'

    $Plan.TaskNames | Should -Be @('Prepare.First', 'Prepare.Second', 'Vendor.Package')
    $Plan.Dependencies['Vendor.Package'] | Should -Be @('Prepare.First', 'Prepare.Second')
  }

  It 'orders transitive dependency tasks before their consumers' {
    New-TestTask -Root $TaskRoot -Name '#Source' -Script '$Global:DumplingsStorage.Source = 1'
    New-TestTask -Root $TaskRoot -Name '#Transform' -Script @'
$Global:DumplingsStorage.Result = $Global:DumplingsStorage.Source + 1
'@ -DependsOn '#Source'
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = $Global:DumplingsStorage.Result' -DependsOn '#Transform'

    $Plan = Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package'

    $Plan.TaskNames | Should -Be @('#Source', '#Transform', 'Vendor.Package')
    $Plan.Dependencies['#Transform'] | Should -Be @('#Source')
  }

  It 'warns about storage dependencies without adding them to the plan' {
    New-TestTask -Root $TaskRoot -Name '#Shared' -Script '$Global:DumplingsStorage.Shared = 1'
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = $Global:DumplingsStorage.Shared'

    $Plan = Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package' -WarningVariable Warnings -WarningAction SilentlyContinue

    $Plan.TaskNames | Should -Be @('Vendor.Package')
    $Plan.Dependencies['Vendor.Package'] | Should -BeNullOrEmpty
    $Plan.UndeclaredStorageDependencies['Vendor.Package'] | Should -Be @('#Shared')
    $Warnings | Should -HaveCount 1
  }

  It 'rejects multiple providers for the same shared key' {
    New-TestTask -Root $TaskRoot -Name '#First' -Script '$Global:DumplingsStorage.Shared = 1'
    New-TestTask -Root $TaskRoot -Name '#Second' -Script '$Global:DumplingsStorage.Shared = 2'
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = $Global:DumplingsStorage.Shared'

    { Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package' } |
      Should -Throw "*DumplingsStorage key 'Shared' has multiple providers*"
  }

  It 'rejects dependency cycles' {
    New-TestTask -Root $TaskRoot -Name '#First' -Script '$Global:DumplingsStorage.First = 1' -DependsOn '#Second'
    New-TestTask -Root $TaskRoot -Name '#Second' -Script '$Global:DumplingsStorage.Second = 1' -DependsOn '#First'
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = 1' -DependsOn '#First'

    { Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package' } |
      Should -Throw '*dependency cycle*'
  }

  It 'rejects a missing explicit dependency' {
    New-TestTask -Root $TaskRoot -Name 'Vendor.Package' -Script '$Value = 1' -DependsOn '#Missing'

    { Resolve-DumplingsTaskDependency -TaskDirectory $TaskRoot -TaskName 'Vendor.Package' } |
      Should -Throw "*depends on missing task '#Missing'*"
  }
}
