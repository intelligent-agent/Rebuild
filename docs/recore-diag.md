# recore-diag (#124)

This initial implementation supersedes the large historical plan on this
branch. A shell entry point wraps the existing Recore-CI board-side workload
and readable formatter. Those two files are copied unchanged from the working
CI implementation; keep fixes synchronized rather than inventing new loads.

```sh
sudo recore-diag                         # basic report; no load/install
sudo recore-diag --stress --minutes 20 --cpu --gpu --memory --interval 5
sudo recore-diag --last
```

Duration is in minutes; interval is 2–30 seconds. Explicitly select the loads.
GPU defaults to offscreen; use `--gpu-mode onscreen` to observe artifacts.
Memory defaults to 128 MiB and repeats to the deadline; at least one complete
locked-memory pass is required. Missing stress tools are installed as needed
with apt-get. The default report does not install them. Python/procps belong
to the existing board support package; there is no new daemon or UI.

Periodic status lines show elapsed/remaining time, named available thermal
zones, CPU/GPU MHz, GPU FPS, memory passes/errors and load state. No JSON is
required at the terminal. Detailed worker output and readable reports are
saved in root-only `/var/lib/recore-diag/<timestamp>/`, outside printer config.
The compact status uses `time:elapsed/remaining`, `mem:completed-passes p/errors e`
and `?` for unavailable readings; detailed unrounded values remain in raw.log.
Compact periodic output is the default. Add `--verbose` for the original detailed
status lines, including load states. This only changes presentation, not the test.
Reports include board identity; review them before sharing. Nothing uploads.

Stress runs refuse active/paused/unknown printer state, existing stress jobs,
missing thermal sensors, insufficient memory headroom and software GPU renderers.
Barebone report-only is supported; barebone stress currently refuses unknown
printer state rather than bypassing the safety gate. Do not start a print during
a run. Thermal cutoff is 88 C by default. Memory errors are counted without
ending the timed run, but make the final result fail. Operational failures and
unsafe temperatures still stop the run. Results can be incomplete if no full
memory pass completes. Clean telemetry cannot rule out physical screen artifacts.

The systemd cgroup provides a board-local deadline and scoped cleanup; Ctrl-C
stops that unit. If the SSH connection vanishes, the local deadline remains.
No clocks, voltages, printer services, display modes or fan settings are changed.
No automatic per-board tuning, reboot campaign or destructive disk tests.

The first report is intentionally basic; expanded crash/storage diagnostics
and broader hardware smoke/cancellation testing remain tracked by #124.
