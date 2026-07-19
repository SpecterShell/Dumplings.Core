# Dumplings.Core

Dumplings.Core is the PowerShell 7.4+ task runner for [Dumplings](https://github.com/SpecterShell/Dumplings). It discovers task directories, resolves explicit dependencies, initializes shared state, loads submodules, runs tasks in one or more thread-job workers, invokes module lifecycle hooks, and performs deterministic cleanup.

Core is infrastructure only. Package-specific behavior belongs in tasks, while reusable package and WinGet behavior belongs in PackageModule.

## Repository Position

Core expects the standard Dumplings layout and should be invoked from the project root:

```text
Dumplings/
+-- Core/
|   `-- Index.ps1
+-- Modules/
|   `-- <module>/Index.ps1
+-- Tasks/
|   `-- <task>/Config.yaml
+-- Preference.yaml
`-- Secret.yaml              # optional and ignored
```

Running from another working directory changes where Core looks for `Preference.yaml`, `.env`, `Modules`, `Tasks`, and `Outputs`.

## Usage

```powershell
# Run all tasks with one worker.
.\Core\Index.ps1

# Run selected tasks and their declared dependencies.
.\Core\Index.ps1 -Name Vendor.Package, Vendor.OtherPackage

# Use an alternate task root.
.\Core\Index.ps1 -Name Vendor.Package -Path C:\Automation\Tasks

# Run four workers and return completed task objects.
.\Core\Index.ps1 -Name Vendor.Package -ThrottleLimit 4 -PassThru
```

| Parameter | Description |
| --- | --- |
| `Name` | Task directory names. When omitted, Core selects every immediate child containing `Config.yaml`. |
| `Path` | Task root. Defaults to `Tasks` under the current working directory. |
| `PassThru` | Returns task objects instead of disposing them after execution. The caller becomes responsible for disposal. |
| `ThrottleLimit` | Worker count. `1` runs in the coordinator runspace; larger values use `Start-ThreadJob`. |
| Remaining arguments | Parsed as preference overrides, for example `-Force`, `-EnableWrite`, or `-Timeout 7200`. |

Core loads `.env`, `Preference.yaml`, `DUMPLINGS_SECRET`, and `Secret.yaml` before building the task plan. Command-line preferences override `Preference.yaml`; `Secret.yaml` overrides matching values from `DUMPLINGS_SECRET`.

## Task Contract

Each task directory must contain:

- `Config.yaml` with a `Type` whose class is provided by a loaded module.
- `Script.ps1`, which the model's `Invoke()` method executes.

Core constructs the task with an ordered dictionary containing `Name`, `Path`, and `Config`. PackageModule currently provides `SimpleTask` and `PackageTask`.

Common configuration:

```yaml
Type: PackageTask
WinGetIdentifier: Vendor.Package
Skip: false
DependsOn:
- '#Vendor'
```

Core does not interpret package fields beyond task construction and dependency planning. Model-specific configuration belongs to the model that consumes it.

## Dependency Planning

`DependsOn` accepts one task name or an array of task names. Core:

1. Recursively includes dependencies of explicitly selected tasks.
2. Rejects missing tasks and dependency cycles.
3. Orders ready tasks deterministically.
4. Waits for every dependency to reach a terminal state.
5. Blocks a dependent task if any dependency did not succeed.

Shared-data tasks commonly begin with `#` and write values to `$Global:DumplingsStorage`. Core statically inspects literal shared-storage access to warn about undeclared providers, but it never silently adds inferred dependencies. Declare every dependency in `Config.yaml`.

## Runner State

Core initializes the following globals for modules and tasks:

| Variable | Purpose |
| --- | --- |
| `$Global:DumplingsRoot` | Project root, taken from the current working directory. |
| `$Global:DumplingsPreference` | Ordered preferences after file and command-line merging. |
| `$Global:DumplingsSecret` | Ordered secret values after environment and file merging. |
| `$Global:DumplingsStorage` | Process-wide synchronized storage shared by worker runspaces. |
| `$Global:DumplingsSessionStorage` | Storage local to one worker runspace. |
| `$Global:DumplingsCache` | Temporary directory removed at runner shutdown. |
| `$Global:DumplingsOutput` | Clean `Outputs` directory for artifacts from the current run. |

Do not use shared storage as an implicit dependency channel. Prefer immutable values and thread-safe objects when data crosses workers.

## Module Loading

Every immediate child of `Modules` may provide an `Index.ps1`. Core dot-sources these files in each worker before constructing tasks. A module should load its libraries and models deterministically and should not assume another module's accidental import order.

Modules may also provide lifecycle scripts under `Hooks`:

| Hook | Scope | Typical use |
| --- | --- | --- |
| `RunnerStarting` | Coordinator, once | Initialize process-wide brokers or shared resources. |
| `WorkerStarting` | Every worker | Initialize runspace-local state. |
| `BeforeTask` | Every task | Assign task ownership or acquisition context. |
| `AfterTask` | Every task | Release resources even after task failure. |
| `WorkerStopping` | Every worker | Dispose runspace-local resources. |
| `BeforeForcedWorkerStop` | Coordinator | Capture diagnostics and stop resources before terminating timed-out workers. |
| `RunnerStopping` | Coordinator, once | Drain queues and dispose process-wide resources. |

Startup and `BeforeTask` hooks run in module-name order and fail fast. Cleanup hooks run in reverse order, attempt every hook, and aggregate failures. Hook scripts receive one mutable `-Context` dictionary; keep module-specific state beneath `Context.Items` to avoid key collisions.

## Concurrency And Timeouts

With `ThrottleLimit` greater than one, Core starts named thread jobs and shares the task queue, dependency signals, storage, and worker diagnostics with them. The coordinator waits up to `Preference.yaml`'s `Timeout` value, records each worker's last dequeued task, invokes forced-stop hooks, and then removes remaining jobs.

[`Libraries/Synchronization.psm1`](Libraries/Synchronization.psm1) provides scoped `Use-Mutex`, `Use-Semaphore`, and `Use-Monitor` helpers. Use these helpers instead of manually acquiring a primitive without a `finally` release path.

## Libraries

| Library | Responsibility |
| --- | --- |
| `ModuleHooks.psm1` | Hook discovery and ordered invocation. |
| `Synchronization.psm1` | Exception-safe mutex, semaphore, and monitor scopes. |
| `TaskDependency.psm1` | Explicit dependency graph and shared-storage diagnostics. |
| `WorkerState.psm1` | Cross-runspace tracking of the task most recently dequeued by each worker. |

## Testing

From the Dumplings root:

```powershell
Invoke-Pester .\Core\Tests
Invoke-ScriptAnalyzer .\Core\Index.ps1, .\Core\Libraries\*.psm1
```

Runner tests should mock external services and must not execute downloaded installers.

## License

Dumplings.Core is licensed under the [MIT License](LICENSE).
