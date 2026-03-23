# macOS Performance Audit

Lightweight audit script for short-lived macOS slowdowns on Apple Silicon Macs.

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
./macos-perf-audit.sh
sudo ./macos-perf-audit.sh --duration 120 --interval 5 --output perf-report.json
```

Useful variants:

```bash
./macos-perf-audit.sh --duration 60 --interval 3 --output perf-report.json
sudo ./macos-perf-audit.sh
```

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
