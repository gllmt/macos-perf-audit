# macOS Performance Audit

Short-window performance diagnostics for Apple Silicon Macs. Run an audit during a slowdown, capture CPU, memory, disk I/O, load, top processes, and optional GPU power metrics, then get a structured JSON report with anomalies and practical next steps.

![Shell](https://img.shields.io/badge/Shell-121011?style=flat-square&logo=gnubash&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-555555?style=flat-square&logo=apple&logoColor=white)
![JSON report](https://img.shields.io/badge/JSON-report-5E5CFF?style=flat-square)
![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg?style=flat-square)

## Features

- Short sampling windows for intermittent macOS slowdowns.
- Structured JSON report with `meta`, `samples`, and `summary` sections.
- CPU, memory, swap, load average, disk I/O, aggregate network activity, and top process snapshots.
- Process rankings with average and peak CPU/RAM usage across the audit window.
- Pattern detection for CPU spikes, disk I/O spikes, memory pressure, swap pressure, and common macOS background services.
- Optional GPU activity and power metrics through `powermetrics` when run with `sudo`.
- Low-noise cleanup helper for optional third-party background activity before an audit.

## Requirements

- macOS, tuned for Apple Silicon Macs.
- Bash plus standard macOS tools: `top`, `ps`, `vm_stat`, `sysctl`, `iostat`, `system_profiler`, and `python3`.
- `sudo` is optional for the main audit, but required for GPU power metrics and Spotlight/background-load controls.

## Quick Start

```bash
chmod +x ./macos-perf-audit.sh ./trim-background-processes.sh
./macos-perf-audit.sh --duration 60 --interval 3 --output perf-report.json
```

For the most useful default trace, run it during the slowdown:

```bash
sudo ./macos-perf-audit.sh --duration 120 --interval 5
```

Without `--output`, reports are written as `perf-report-YYYYMMDD-HHMMSS.json`.

## Low-Noise Baseline

Use the cleanup helper when you want a cleaner baseline before measuring.
Persistent disable is enabled by default for matching third-party launchd jobs; add `--no-persist` for a session-only cleanup.

```bash
./trim-background-processes.sh --status
./trim-background-processes.sh --dry-run --spotlight --extras
sudo ./trim-background-processes.sh --spotlight --extras
sudo ./macos-perf-audit.sh --duration 120 --interval 5
```

To re-enable Spotlight indexing and launchd jobs disabled by the helper:

```bash
sudo ./trim-background-processes.sh --spotlight-on
```

For the full cleanup workflow, see [LOAD_REDUCTION.md](./LOAD_REDUCTION.md).

## What It Collects

- System metadata: model, chip, core count, RAM, macOS version/build, uptime, and root disk summary.
- CPU usage from `top`.
- Memory, swap, and pressure from `top`, `vm_stat`, and `sysctl`.
- Load average from `sysctl`.
- Disk throughput from `iostat` and `top`.
- Aggregate network byte and packet counters from `top`.
- Top CPU and RAM processes from `ps`.
- GPU profile from `system_profiler`.
- GPU power/activity from `powermetrics` when available and run with `sudo`.

## Output

The script prints a compact terminal summary and writes a JSON report:

```json
{
  "meta": {
    "report_version": "2.0.0",
    "generated_at": "2026-07-05T12:00:00Z",
    "sampling": {
      "interval_seconds": 5,
      "requested_duration_seconds": 120,
      "actual_samples": 24,
      "gpu_power_collected": true
    }
  },
  "samples": [],
  "summary": {
    "cpu": {
      "avg_total_pct": 17.2,
      "peak_total_pct": 88.4
    },
    "memory": {
      "avg_used_gb": 23.0,
      "peak_swap_mb": 5606.12,
      "pressure_levels_observed": ["warn"]
    },
    "patterns": [
      "2 memory-pressure event(s) reached warn/critical."
    ],
    "recommendations": [
      "Close high-memory applications first; memory pressure already reached warning or critical."
    ]
  }
}
```

`samples` contains the raw per-interval snapshots. `summary` contains the ranking, spikes, anomalies, patterns, and recommendations that are easiest to read first.

## Commands

```bash
./macos-perf-audit.sh --help
./macos-perf-audit.sh --duration 60 --interval 3 --top 15 --output perf-report.json
sudo ./macos-perf-audit.sh

./trim-background-processes.sh --help
./trim-background-processes.sh --status
./trim-background-processes.sh --dry-run --spotlight --extras
sudo ./trim-background-processes.sh --spotlight --extras
sudo ./trim-background-processes.sh --spotlight-on
```

Environment overrides are also supported:

```bash
PERF_DURATION=300 PERF_INTERVAL=10 PERF_TOP_N=20 PERF_OUTPUT=perf-report.json ./macos-perf-audit.sh
```

## Privacy

Reports can include hostname, hardware model, macOS build, root disk summary, process names, PIDs, resource usage, and aggregate disk/network activity. Review the JSON before sharing it publicly.

The audit does not intentionally collect file contents, browser history, command history, IP addresses, environment variables, or secrets.

## Limitations

- This is a diagnostic trace, not a benchmark. Re-run it while the slowdown is happening.
- GPU power metrics depend on `powermetrics`, Apple Silicon support, and `sudo`.
- The cleanup helper is conservative and targets specific optional apps/helpers. Use `--dry-run` before applying it.
- Some Spotlight processes may remain loaded at `0.0%` CPU even after indexing is disabled.

## Repository Layout

- `macos-perf-audit.sh`: collect a short performance trace and generate a JSON report.
- `trim-background-processes.sh`: stop optional third-party helpers and reduce background activity before an audit.
- `LOAD_REDUCTION.md`: detailed low-noise cleanup workflow.

## License

Licensed under the [GNU AGPL-3.0](LICENSE). You are free to use, study, modify, and redistribute it. Any distributed or network-hosted fork must also be released under the AGPL-3.0, which keeps derivatives open.

© 2026 Pierre Guillemot
