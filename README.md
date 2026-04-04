# macOS Performance Audit

Lightweight audit script for short-lived macOS slowdowns on Apple Silicon Macs.

## Repository Layout

- `macos-perf-audit.sh`: collect a short performance trace and generate a JSON report
- `trim-background-processes.sh`: stop optional third-party helpers and reduce background activity before an audit

## What It Collects

- Global CPU usage from `top`
- Top CPU and RAM processes from `ps`
- Memory usage, swap, and pressure from `top`, `vm_stat`, and `sysctl`
- Disk throughput from `iostat`
- Load average from `sysctl`
- GPU power/activity from `powermetrics` when run with `sudo`

## Quick Start

```bash
chmod +x ./macos-perf-audit.sh
chmod +x ./trim-background-processes.sh
./macos-perf-audit.sh
sudo ./macos-perf-audit.sh --duration 120 --interval 5 --output perf-report.json
```

Useful variants:

```bash
./macos-perf-audit.sh --duration 60 --interval 3 --output perf-report.json
sudo ./macos-perf-audit.sh
```

## Reduce Background Load Before an Audit

Use the helper script when you want a cleaner baseline before running the audit.

Default targets:

- AdGuard
- LogiOptionsPlus
- Figma

Optional targets:

- BetterDisplay
- Spotlight indexing

Preview what it would do:

```bash
./trim-background-processes.sh --dry-run --spotlight --extras
```

Recommended "lowest-noise" baseline:

```bash
sudo ./trim-background-processes.sh --spotlight --extras
sudo ./macos-perf-audit.sh --duration 120 --interval 5
```

To check what is still running after cleanup:

```bash
./trim-background-processes.sh --status
ps -axo pid,pcpu,pmem,rss,args | rg -i 'logi|adguard|figma|betterdisplay|spotlight|corespotlight|mds|mdworker'
```

To re-enable Spotlight indexing later:

```bash
sudo ./trim-background-processes.sh --spotlight-on
```

For a more detailed cleanup workflow, see [LOAD_REDUCTION.md](./LOAD_REDUCTION.md).

## Output

The script writes a JSON report with:

- `meta`: machine info, macOS version, sampling config
- `samples`: timestamped snapshots every few seconds
- `summary`: top CPU/RAM consumers, spikes, anomalies, and recommendations

## Example Summary Snippet

```json
{
  "summary": {
    "cpu": {
      "avg_total_pct": 17.2,
      "peak_total_pct": 18.3
    },
    "memory": {
      "avg_used_gb": 23.0,
      "peak_swap_mb": 5606.12,
      "pressure_levels_observed": ["warn"]
    },
    "top_cpu_consumers": [
      {
        "pid": 400,
        "name": "WindowServer",
        "avg_cpu_pct_when_present": 48.0,
        "peak_cpu_pct": 49.7
      }
    ],
    "top_ram_consumers": [
      {
        "pid": 35505,
        "name": "OrbStack Helper",
        "peak_rss_mb": 2260.0
      }
    ],
    "patterns": [
      "2 memory-pressure event(s) reached warn/critical."
    ],
    "recommendations": [
      "Close high-memory applications first; memory pressure already reached warning or critical.",
      "Run with sudo to include GPU power metrics: sudo ./macos-perf-audit.sh"
    ]
  }
}
```
