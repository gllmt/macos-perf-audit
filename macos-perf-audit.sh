#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# macos-perf-audit.sh
# Lightweight macOS performance diagnostic tool for Apple Silicon Macs.
# Collects CPU, memory, disk I/O, GPU power (when run with sudo), and process
# hotspots over a short sampling window, then produces a structured JSON report.
#
# Examples:
#   chmod +x macos-perf-audit.sh
#   ./macos-perf-audit.sh
#   ./macos-perf-audit.sh --duration 60 --interval 3 --output report.json
#   sudo ./macos-perf-audit.sh
#
# Environment overrides:
#   PERF_DURATION=120
#   PERF_INTERVAL=5
#   PERF_TOP_N=10
#   PERF_OUTPUT=perf-report.json
# =============================================================================

SCRIPT_NAME=$(basename "$0")
DEFAULT_INTERVAL=5
DEFAULT_DURATION=120
DEFAULT_TOP_N=10

INTERVAL=${PERF_INTERVAL:-$DEFAULT_INTERVAL}
DURATION=${PERF_DURATION:-$DEFAULT_DURATION}
TOP_N=${PERF_TOP_N:-$DEFAULT_TOP_N}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE=${PERF_OUTPUT:-perf-report-${TIMESTAMP}.json}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/perf-audit.XXXXXX")
IS_ROOT=$([ "$(id -u)" -eq 0 ] && echo 1 || echo 0)
POWERMETRICS_AVAILABLE=0
NUM_SAMPLES=0
INTERRUPTED=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  -d, --duration <seconds>   Total capture duration. Default: ${DEFAULT_DURATION}
  -i, --interval <seconds>   Sampling interval. Default: ${DEFAULT_INTERVAL}
  -n, --top <count>          Processes per ranking. Default: ${DEFAULT_TOP_N}
  -o, --output <file>        Output JSON path. Default: perf-report-<timestamp>.json
  -h, --help                 Show this help.

Environment overrides:
  PERF_DURATION, PERF_INTERVAL, PERF_TOP_N, PERF_OUTPUT
EOF
}

fail() {
    echo "[!] $*" >&2
    exit 1
}

warn() {
    echo "[!] $*" >&2
}

progress() {
    printf "\r\033[K  [%s] %s" "$(date +%H:%M:%S)" "$1" >&2
}

cleanup() {
    rm -rf "$WORK_DIR"
}

handle_interrupt() {
    INTERRUPTED=1
    echo "" >&2
    warn "Interrupted. Generating a partial report from collected samples."
}

trap cleanup EXIT
trap handle_interrupt INT TERM

is_positive_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

report_path() {
    case "$REPORT_FILE" in
        /*) printf "%s\n" "$REPORT_FILE" ;;
        *) printf "%s/%s\n" "$(pwd)" "$REPORT_FILE" ;;
    esac
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--duration)
                [ $# -ge 2 ] || fail "Missing value for $1"
                DURATION=$2
                shift 2
                ;;
            -i|--interval)
                [ $# -ge 2 ] || fail "Missing value for $1"
                INTERVAL=$2
                shift 2
                ;;
            -n|--top)
                [ $# -ge 2 ] || fail "Missing value for $1"
                TOP_N=$2
                shift 2
                ;;
            -o|--output)
                [ $# -ge 2 ] || fail "Missing value for $1"
                REPORT_FILE=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done
}

validate_config() {
    is_positive_int "$INTERVAL" || fail "Interval must be a positive integer."
    is_positive_int "$DURATION" || fail "Duration must be a positive integer."
    is_positive_int "$TOP_N" || fail "Top count must be a positive integer."

    if [ "$INTERVAL" -lt 2 ] || [ "$INTERVAL" -gt 30 ]; then
        warn "Recommended interval is between 2 and 30 seconds. Current: ${INTERVAL}s."
    fi

    NUM_SAMPLES=$(((DURATION + INTERVAL - 1) / INTERVAL))

    require_command date
    require_command mktemp
    require_command top
    require_command ps
    require_command vm_stat
    require_command sysctl
    require_command iostat
    require_command python3

    if command -v powermetrics >/dev/null 2>&1; then
        POWERMETRICS_AVAILABLE=1
    fi

    mkdir -p "$(dirname "$REPORT_FILE")"
}

run_powermetrics_snapshot() {
    local output_file=$1

    [ "$IS_ROOT" -eq 1 ] || return 0
    [ "$POWERMETRICS_AVAILABLE" -eq 1 ] || return 0

    powermetrics --samplers gpu_power -i 1000 -n 1 > "$output_file" 2>/dev/null || true
}

collect_system_info() {
    progress "Collecting system metadata..."
    local dir="$WORK_DIR/sysinfo"
    mkdir -p "$dir"

    hostname > "$dir/hostname" 2>/dev/null || true
    sw_vers > "$dir/swvers" 2>/dev/null || true
    sysctl -n hw.model > "$dir/model" 2>/dev/null || true
    sysctl -n hw.ncpu > "$dir/ncpu" 2>/dev/null || true
    sysctl -n hw.physicalcpu > "$dir/physicalcpu" 2>/dev/null || true
    sysctl -n hw.memsize > "$dir/memsize" 2>/dev/null || true
    sysctl -n hw.perflevel0.physicalcpu > "$dir/pcores" 2>/dev/null || true
    sysctl -n hw.perflevel1.physicalcpu > "$dir/ecores" 2>/dev/null || true
    uptime > "$dir/uptime" 2>/dev/null || true
    df -h / > "$dir/root_disk" 2>/dev/null || true

    system_profiler SPHardwareDataType -detailLevel mini 2>/dev/null > "$dir/hardware_profile" || true
    system_profiler SPDisplaysDataType -detailLevel mini 2>/dev/null > "$dir/gpu_profile" || true

    if [ "$IS_ROOT" -eq 1 ] && [ "$POWERMETRICS_AVAILABLE" -eq 1 ]; then
        run_powermetrics_snapshot "$dir/gpu_power"
    fi
}

collect_sample() {
    local sample_index=$1
    local dir="$WORK_DIR/samples/$sample_index"
    local top_pid io_pid gpu_pid

    mkdir -p "$dir"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/timestamp"

    # Use the second top/iostat frame for an instantaneous 1-second delta sample.
    top -l 2 -n 0 -s 1 > "$dir/top_summary" 2>/dev/null &
    top_pid=$!

    iostat -d -c 2 -w 1 > "$dir/iostat" 2>/dev/null &
    io_pid=$!

    sysctl -n vm.loadavg > "$dir/loadavg" 2>/dev/null || true
    vm_stat > "$dir/vmstat" 2>/dev/null || true
    sysctl vm.swapusage > "$dir/swap" 2>/dev/null || true
    sysctl -n kern.memorystatus_vm_pressure_level > "$dir/pressure_level" 2>/dev/null \
        || echo "-1" > "$dir/pressure_level"

    {
        echo "PID %CPU %MEM RSS COMM"
        LC_ALL=C ps -A -c -o pid=,pcpu=,pmem=,rss=,comm= 2>/dev/null | sort -k2 -nr | head -"$TOP_N"
    } > "$dir/top_cpu_procs"

    {
        echo "PID %CPU %MEM RSS COMM"
        LC_ALL=C ps -A -c -o pid=,pcpu=,pmem=,rss=,comm= 2>/dev/null | sort -k4 -nr | head -"$TOP_N"
    } > "$dir/top_mem_procs"

    gpu_pid=""
    if [ "$IS_ROOT" -eq 1 ] && [ "$POWERMETRICS_AVAILABLE" -eq 1 ]; then
        run_powermetrics_snapshot "$dir/gpu_power" &
        gpu_pid=$!
    fi

    wait "$top_pid" 2>/dev/null || true
    wait "$io_pid" 2>/dev/null || true

    if [ -n "$gpu_pid" ]; then
        wait "$gpu_pid" 2>/dev/null || true
    fi
}

generate_report() {
    WORK_DIR="$WORK_DIR" \
    REPORT_FILE="$REPORT_FILE" \
    INTERVAL="$INTERVAL" \
    DURATION="$DURATION" \
    NUM_SAMPLES="$NUM_SAMPLES" \
    TOP_N="$TOP_N" \
    IS_ROOT="$IS_ROOT" \
    INTERRUPTED="$INTERRUPTED" \
    POWERMETRICS_AVAILABLE="$POWERMETRICS_AVAILABLE" \
    python3 <<'PYEOF'
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

WORK_DIR = Path(os.environ["WORK_DIR"])
REPORT_FILE = Path(os.environ["REPORT_FILE"])
INTERVAL = int(os.environ["INTERVAL"])
DURATION = int(os.environ["DURATION"])
NUM_SAMPLES = int(os.environ["NUM_SAMPLES"])
TOP_N = int(os.environ["TOP_N"])
IS_ROOT = os.environ.get("IS_ROOT", "0") == "1"
INTERRUPTED = os.environ.get("INTERRUPTED", "0") == "1"
POWERMETRICS_AVAILABLE = os.environ.get("POWERMETRICS_AVAILABLE", "0") == "1"

PRESSURE_LABELS = {
    -1: "unknown",
    0: "nominal",
    1: "normal",
    2: "warn",
    4: "critical",
}

KNOWN_ISSUES = {
    "kernel_task": "High kernel_task CPU often points to thermal throttling or a hardware-level backpressure condition.",
    "windowserver": "High WindowServer CPU usually means expensive compositing, many windows, or external-display pressure.",
    "mds": "Spotlight indexing is running and can temporarily impact responsiveness.",
    "mds_stores": "Spotlight indexing is running and can temporarily impact responsiveness.",
    "mdworker": "Spotlight worker activity is ongoing.",
    "mdworker_shared": "Spotlight worker activity is ongoing.",
    "backupd": "Time Machine backup is active and can drive disk and CPU load.",
    "cloudd": "iCloud synchronization is active and may create background CPU, disk, and network load.",
    "bird": "iCloud Drive synchronization is active.",
    "nsurlsessiond": "Background transfers are in progress.",
    "photolibraryd": "Photos analysis or synchronization is active.",
    "mediaanalysisd": "Media analysis is active in the background.",
    "rapportd": "Nearby-device communication is active.",
    "suggestd": "Suggestions indexing is active.",
}


def read_file(path: Path) -> str:
    try:
        return path.read_text().strip()
    except Exception:
        return ""


def avg(values):
    return round(sum(values) / len(values), 2) if values else 0.0


def peak(values):
    return round(max(values), 2) if values else 0.0


def clamp_non_negative(value):
    return round(value if value > 0 else 0.0, 2)


def size_to_mb(token):
    if not token:
        return 0.0
    match = re.match(r"([\d.]+)\s*([BKMGT])", token.strip())
    if not match:
        return 0.0
    value = float(match.group(1))
    unit = match.group(2)
    factors = {
        "B": 1.0 / (1024 * 1024),
        "K": 1.0 / 1024,
        "M": 1.0,
        "G": 1024.0,
        "T": 1024.0 * 1024.0,
    }
    return value * factors[unit]


def size_to_gb(token):
    return round(size_to_mb(token) / 1024.0, 2)


def normalize_process_name(name):
    return name.strip().split("/")[-1].lower()


def parse_top_cpu(text):
    cpu = {"user_pct": 0.0, "sys_pct": 0.0, "idle_pct": 100.0, "total_pct": 0.0}
    cpu_lines = [line.strip() for line in text.splitlines() if "CPU usage:" in line]
    if not cpu_lines:
        return cpu

    line = cpu_lines[-1]
    for value, label in re.findall(r"([\d.]+)%\s+(user|sys|idle)", line):
        key = f"{label}_pct"
        cpu[key] = float(value)
    cpu["total_pct"] = round(cpu["user_pct"] + cpu["sys_pct"], 2)
    return cpu


def parse_physmem_line(line):
    info = {
        "used_gb": None,
        "unused_gb": None,
        "wired_mb": None,
        "compressor_gb": None,
    }

    used = re.search(r"PhysMem:\s+([\d.]+[BKMGT])\s+used", line)
    unused = re.search(r",\s*([\d.]+[BKMGT])\s+unused", line)
    if used:
        info["used_gb"] = size_to_gb(used.group(1))
    if unused:
        info["unused_gb"] = size_to_gb(unused.group(1))

    details = re.search(r"\(([^)]*)\)", line)
    if details:
        for item in details.group(1).split(","):
            part = item.strip()
            metric = re.match(r"([\d.]+[BKMGT])\s+(.+)", part)
            if not metric:
                continue
            size_token, label = metric.groups()
            normalized = label.strip().replace(" ", "_")
            if normalized == "wired":
                info["wired_mb"] = round(size_to_mb(size_token), 2)
            elif normalized == "compressor":
                info["compressor_gb"] = round(size_to_gb(size_token), 2)
    return info


def parse_vm_line(line):
    info = {}
    swapins = re.search(r"(\d+)\((\d+)\)\s+swapins", line)
    swapouts = re.search(r"(\d+)\((\d+)\)\s+swapouts", line)
    if swapins:
        info["swapins_total"] = int(swapins.group(1))
        info["swapins_delta"] = int(swapins.group(2))
    if swapouts:
        info["swapouts_total"] = int(swapouts.group(1))
        info["swapouts_delta"] = int(swapouts.group(2))
    return info


def parse_disk_line(line):
    match = re.search(
        r"Disks:\s+(\d+)\/([\d.]+[BKMGT])\s+read,\s+(\d+)\/([\d.]+[BKMGT])\s+written",
        line,
    )
    if not match:
        return {}

    read_ops, read_size, write_ops, write_size = match.groups()
    return {
        "read_ops_total": int(read_ops),
        "read_total_mb": round(size_to_mb(read_size), 2),
        "write_ops_total": int(write_ops),
        "write_total_mb": round(size_to_mb(write_size), 2),
    }


def parse_network_line(line):
    match = re.search(
        r"Networks:\s+packets:\s+(\d+)\/([\d.]+[BKMGT])\s+in,\s+(\d+)\/([\d.]+[BKMGT])\s+out",
        line,
    )
    if not match:
        return {}
    packets_in, bytes_in, packets_out, bytes_out = match.groups()
    return {
        "packets_in_total": int(packets_in),
        "packets_out_total": int(packets_out),
        "bytes_in_total_mb": round(size_to_mb(bytes_in), 2),
        "bytes_out_total_mb": round(size_to_mb(bytes_out), 2),
    }


def parse_top_overview(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    cpu = parse_top_cpu(text)

    physmem_lines = [line for line in lines if line.startswith("PhysMem:")]
    vm_lines = [line for line in lines if line.startswith("VM:")]
    disk_lines = [line for line in lines if line.startswith("Disks:")]
    network_lines = [line for line in lines if line.startswith("Networks:")]

    physmem = parse_physmem_line(physmem_lines[-1]) if physmem_lines else {}
    vm = parse_vm_line(vm_lines[-1]) if vm_lines else {}

    disks = {}
    if disk_lines:
        current = parse_disk_line(disk_lines[-1])
        previous = parse_disk_line(disk_lines[-2]) if len(disk_lines) > 1 else {}
        if current:
            disks.update(current)
            if previous:
                disks["read_delta_mb"] = clamp_non_negative(
                    current.get("read_total_mb", 0.0) - previous.get("read_total_mb", 0.0)
                )
                disks["write_delta_mb"] = clamp_non_negative(
                    current.get("write_total_mb", 0.0) - previous.get("write_total_mb", 0.0)
                )

    networks = {}
    if network_lines:
        current = parse_network_line(network_lines[-1])
        previous = parse_network_line(network_lines[-2]) if len(network_lines) > 1 else {}
        if current:
            networks.update(current)
            if previous:
                networks["bytes_in_delta_mb"] = clamp_non_negative(
                    current.get("bytes_in_total_mb", 0.0) - previous.get("bytes_in_total_mb", 0.0)
                )
                networks["bytes_out_delta_mb"] = clamp_non_negative(
                    current.get("bytes_out_total_mb", 0.0) - previous.get("bytes_out_total_mb", 0.0)
                )

    return {
        "cpu": cpu,
        "physmem": physmem,
        "vm": vm,
        "disks": disks,
        "networks": networks,
    }


def parse_vmstat(text):
    stats = {"_page_size": 16384}
    page_size = re.search(r"page size of (\d+) bytes", text)
    if page_size:
        stats["_page_size"] = int(page_size.group(1))

    for line in text.splitlines():
        match = re.match(r'(.+?):\s+([\d]+)', line)
        if not match:
            continue
        key = match.group(1).strip().lower().replace(" ", "_").replace('"', "")
        stats[key] = int(match.group(2))
    return stats


def parse_swap(text):
    result = {"total_mb": 0.0, "used_mb": 0.0, "free_mb": 0.0}
    match = re.search(
        r"total\s*=\s*([\d.]+)([MG])\s+used\s*=\s*([\d.]+)([MG])\s+free\s*=\s*([\d.]+)([MG])",
        text,
    )
    if not match:
        return result

    total_val, total_unit, used_val, used_unit, free_val, free_unit = match.groups()

    def to_mb(value, unit):
        factor = 1024.0 if unit == "G" else 1.0
        return round(float(value) * factor, 2)

    result["total_mb"] = to_mb(total_val, total_unit)
    result["used_mb"] = to_mb(used_val, used_unit)
    result["free_mb"] = to_mb(free_val, free_unit)
    return result


def parse_loadavg(text):
    values = re.findall(r"[\d.]+", text)
    if len(values) < 3:
        return {"1m": 0.0, "5m": 0.0, "15m": 0.0}
    return {"1m": float(values[0]), "5m": float(values[1]), "15m": float(values[2])}


def parse_ps_procs(text):
    processes = []
    lines = [line for line in text.splitlines() if line.strip()]
    for line in lines[1:]:
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, cpu_pct, mem_pct, rss_kb, name = parts
        try:
            processes.append(
                {
                    "pid": int(pid),
                    "cpu_pct": float(cpu_pct),
                    "mem_pct": float(mem_pct),
                    "rss_mb": round(int(rss_kb) / 1024.0, 2),
                    "name": name.strip(),
                }
            )
        except ValueError:
            continue
    return processes


def parse_iostat(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 3:
        return {"device": None, "kb_per_transfer": 0.0, "transactions_per_sec": 0.0, "mb_per_sec": 0.0}

    device = lines[0].split()[0] if lines[0].split() else None
    values = lines[-1].split()
    if len(values) < 3:
        return {"device": device, "kb_per_transfer": 0.0, "transactions_per_sec": 0.0, "mb_per_sec": 0.0}

    try:
        return {
            "device": device,
            "kb_per_transfer": round(float(values[0]), 2),
            "transactions_per_sec": round(float(values[1]), 2),
            "mb_per_sec": round(float(values[2]), 2),
        }
    except ValueError:
        return {"device": device, "kb_per_transfer": 0.0, "transactions_per_sec": 0.0, "mb_per_sec": 0.0}


def parse_gpu_profile(text):
    info = {"chipset": "Unknown", "vram": "Unified Memory"}
    for line in text.splitlines():
        stripped = line.strip()
        if "Chipset Model" in stripped:
            info["chipset"] = stripped.split(":", 1)[-1].strip()
        elif "VRAM" in stripped:
            info["vram"] = stripped.split(":", 1)[-1].strip()
        elif "Total Number of Cores" in stripped and info["vram"] == "Unified Memory":
            info["cores"] = stripped.split(":", 1)[-1].strip()
    return info


def parse_gpu_power(text):
    result = {}
    for line in text.splitlines():
        lower = line.lower()
        if "gpu power" in lower:
            power = re.search(r"([\d.]+)\s*mw", lower)
            if power:
                result["power_mw"] = float(power.group(1))
        if "gpu active" in lower or "active residency" in lower:
            active = re.search(r"([\d.]+)%", lower)
            if active:
                result["active_pct"] = float(active.group(1))
    return result or None


def merge_process_lists(cpu_processes, mem_processes):
    merged = {}
    for rank, process in enumerate(cpu_processes, start=1):
        entry = dict(process)
        entry["cpu_rank"] = rank
        merged[process["pid"]] = entry

    for rank, process in enumerate(mem_processes, start=1):
        if process["pid"] in merged:
            merged[process["pid"]]["memory_rank"] = rank
            merged[process["pid"]]["rss_mb"] = process["rss_mb"]
            merged[process["pid"]]["mem_pct"] = process["mem_pct"]
        else:
            entry = dict(process)
            entry["memory_rank"] = rank
            merged[process["pid"]] = entry

    return sorted(
        merged.values(),
        key=lambda item: (item.get("cpu_pct", 0.0), item.get("rss_mb", 0.0)),
        reverse=True,
    )


sys_dir = WORK_DIR / "sysinfo"
hostname = read_file(sys_dir / "hostname")
chip = ""
hardware_profile = read_file(sys_dir / "hardware_profile")
for line in hardware_profile.splitlines():
    if "Chip:" in line:
        chip = line.split(":", 1)[-1].strip()
        break

swvers = read_file(sys_dir / "swvers")
macos_product_name = ""
macos_version = ""
macos_version_extra = ""
macos_build = ""
for line in swvers.splitlines():
    stripped = line.strip()
    if stripped.startswith("ProductName:"):
        macos_product_name = stripped.split(":", 1)[-1].strip()
    elif stripped.startswith("ProductVersion:"):
        macos_version = stripped.split(":", 1)[-1].strip()
    elif stripped.startswith("ProductVersionExtra:"):
        macos_version_extra = stripped.split(":", 1)[-1].strip()
    elif stripped.startswith("BuildVersion:"):
        macos_build = stripped.split(":", 1)[-1].strip()

memsize_bytes = int(read_file(sys_dir / "memsize") or "0")
memsize_gb = round(memsize_bytes / (1024 ** 3), 2) if memsize_bytes else 0.0
gpu_info = parse_gpu_profile(read_file(sys_dir / "gpu_profile"))
root_disk = read_file(sys_dir / "root_disk")

samples = []
cpu_totals = []
cpu_user = []
cpu_sys = []
memory_used = []
swap_used = []
disk_mb_s = []
disk_read_delta = []
disk_write_delta = []
gpu_power_values = []
gpu_active_values = []
pressure_levels = []
pressure_events = []
process_records = {}

for index in range(1, NUM_SAMPLES + 1):
    sample_dir = WORK_DIR / "samples" / str(index)
    if not sample_dir.is_dir():
        continue

    timestamp = read_file(sample_dir / "timestamp")
    top_overview = parse_top_overview(read_file(sample_dir / "top_summary"))
    vmstat = parse_vmstat(read_file(sample_dir / "vmstat"))
    load_average = parse_loadavg(read_file(sample_dir / "loadavg"))
    swap = parse_swap(read_file(sample_dir / "swap"))
    disk_io = parse_iostat(read_file(sample_dir / "iostat"))
    cpu_processes = parse_ps_procs(read_file(sample_dir / "top_cpu_procs"))
    mem_processes = parse_ps_procs(read_file(sample_dir / "top_mem_procs"))
    high_resource_processes = merge_process_lists(cpu_processes, mem_processes)
    pressure_raw = int(read_file(sample_dir / "pressure_level") or "-1")
    pressure_label = PRESSURE_LABELS.get(pressure_raw, "unknown")

    top_physmem = top_overview.get("physmem", {})
    page_size = vmstat.get("_page_size", 16384)
    free_bytes = (
        vmstat.get("pages_free", 0) + vmstat.get("pages_speculative", 0)
    ) * page_size
    fallback_used_gb = round(
        max(memsize_bytes - free_bytes, 0) / (1024 ** 3), 2
    ) if memsize_bytes else 0.0
    used_gb = top_physmem.get("used_gb")
    if used_gb is None:
        used_gb = fallback_used_gb

    sample = {
        "timestamp": timestamp,
        "sample_index": index,
        "load_average": load_average,
        "cpu": top_overview["cpu"],
        "memory": {
            "used_gb": round(used_gb, 2),
            "unused_gb": top_physmem.get("unused_gb"),
            "wired_mb": top_physmem.get("wired_mb"),
            "compressor_gb": top_physmem.get("compressor_gb"),
            "swap_used_mb": swap.get("used_mb", 0.0),
            "swap_total_mb": swap.get("total_mb", 0.0),
            "pressure": pressure_label,
            "pageins": vmstat.get("pageins", 0),
            "pageouts": vmstat.get("pageouts", 0),
            "swapins": vmstat.get("swapins", 0),
            "swapouts": vmstat.get("swapouts", 0),
            "pages_free": vmstat.get("pages_free", 0),
            "pages_active": vmstat.get("pages_active", 0),
            "pages_inactive": vmstat.get("pages_inactive", 0),
            "pages_wired_down": vmstat.get("pages_wired_down", 0),
            "pages_stored_in_compressor": vmstat.get("pages_stored_in_compressor", 0),
        },
        "disk_io": {
            **disk_io,
            **top_overview.get("disks", {}),
        },
        "diagnostics": {
            "vm": top_overview.get("vm", {}),
            "network": top_overview.get("networks", {}),
        },
        "top_cpu_processes": cpu_processes[:TOP_N],
        "top_memory_processes": mem_processes[:TOP_N],
        "high_resource_processes": high_resource_processes[:TOP_N],
    }

    gpu_data = None
    gpu_file = sample_dir / "gpu_power"
    if gpu_file.exists():
        gpu_data = parse_gpu_power(read_file(gpu_file))
        if gpu_data:
            sample["gpu"] = gpu_data

    samples.append(sample)
    cpu_totals.append(sample["cpu"].get("total_pct", 0.0))
    cpu_user.append(sample["cpu"].get("user_pct", 0.0))
    cpu_sys.append(sample["cpu"].get("sys_pct", 0.0))
    memory_used.append(sample["memory"]["used_gb"])
    swap_used.append(sample["memory"]["swap_used_mb"])
    pressure_levels.append(pressure_label)

    if pressure_label in {"warn", "critical"}:
        pressure_events.append(
            {
                "timestamp": timestamp,
                "pressure": pressure_label,
                "swap_used_mb": sample["memory"]["swap_used_mb"],
                "used_gb": sample["memory"]["used_gb"],
            }
        )

    if sample["disk_io"].get("mb_per_sec") is not None:
        disk_mb_s.append(sample["disk_io"].get("mb_per_sec", 0.0))
    if sample["disk_io"].get("read_delta_mb") is not None:
        disk_read_delta.append(sample["disk_io"].get("read_delta_mb", 0.0))
    if sample["disk_io"].get("write_delta_mb") is not None:
        disk_write_delta.append(sample["disk_io"].get("write_delta_mb", 0.0))

    if gpu_data:
        if "power_mw" in gpu_data:
            gpu_power_values.append(gpu_data["power_mw"])
        if "active_pct" in gpu_data:
            gpu_active_values.append(gpu_data["active_pct"])

    for process in cpu_processes:
        record = process_records.setdefault(
            process["pid"],
            {"pid": process["pid"], "name": process["name"], "cpu_samples": [], "rss_samples": []},
        )
        record["name"] = process["name"]
        record["cpu_samples"].append(process["cpu_pct"])

    for process in mem_processes:
        record = process_records.setdefault(
            process["pid"],
            {"pid": process["pid"], "name": process["name"], "cpu_samples": [], "rss_samples": []},
        )
        record["name"] = process["name"]
        record["rss_samples"].append(process["rss_mb"])

actual_sample_count = len(samples)
first_timestamp = samples[0]["timestamp"] if samples else None
last_timestamp = samples[-1]["timestamp"] if samples else None
generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

top_cpu_consumers = sorted(
    [
        {
            "pid": record["pid"],
            "name": record["name"],
            "samples_seen": len(record["cpu_samples"]),
            "avg_cpu_pct_when_present": avg(record["cpu_samples"]),
            "audit_avg_cpu_pct": round(sum(record["cpu_samples"]) / actual_sample_count, 2)
            if actual_sample_count
            else 0.0,
            "peak_cpu_pct": peak(record["cpu_samples"]),
        }
        for record in process_records.values()
        if record["cpu_samples"]
    ],
    key=lambda item: (item["audit_avg_cpu_pct"], item["peak_cpu_pct"]),
    reverse=True,
)[:TOP_N]

top_ram_consumers = sorted(
    [
        {
            "pid": record["pid"],
            "name": record["name"],
            "samples_seen": len(record["rss_samples"]),
            "avg_rss_mb_when_present": avg(record["rss_samples"]),
            "audit_avg_rss_mb": round(sum(record["rss_samples"]) / actual_sample_count, 2)
            if actual_sample_count
            else 0.0,
            "peak_rss_mb": peak(record["rss_samples"]),
        }
        for record in process_records.values()
        if record["rss_samples"]
    ],
    key=lambda item: (item["peak_rss_mb"], item["audit_avg_rss_mb"]),
    reverse=True,
)[:TOP_N]

avg_total_cpu = avg(cpu_totals)
cpu_spike_threshold = max(85.0, avg_total_cpu + 20.0)
cpu_spikes = []
for sample in samples:
    if sample["cpu"]["total_pct"] >= cpu_spike_threshold:
        cpu_spikes.append(
            {
                "timestamp": sample["timestamp"],
                "total_cpu_pct": sample["cpu"]["total_pct"],
                "lead_processes": [
                    {
                        "pid": process["pid"],
                        "name": process["name"],
                        "cpu_pct": process["cpu_pct"],
                    }
                    for process in sample["top_cpu_processes"][:3]
                ],
            }
        )

avg_disk_mb_s = avg(disk_mb_s)
disk_spike_threshold = max(50.0, avg_disk_mb_s + 25.0)
disk_spikes = []
for sample in samples:
    throughput = sample["disk_io"].get("mb_per_sec", 0.0)
    if throughput >= disk_spike_threshold:
        disk_spikes.append(
            {
                "timestamp": sample["timestamp"],
                "mb_per_sec": throughput,
                "write_delta_mb": sample["disk_io"].get("write_delta_mb"),
                "read_delta_mb": sample["disk_io"].get("read_delta_mb"),
            }
        )

anomalies = []
seen_anomaly_keys = set()

for process in top_cpu_consumers:
    name_key = normalize_process_name(process["name"])
    if process["avg_cpu_pct_when_present"] >= 50 or (
        process["peak_cpu_pct"] >= 80 and process["samples_seen"] >= 2
    ):
        detail = (
            f"{process['name']} (pid {process['pid']}) averaged "
            f"{process['avg_cpu_pct_when_present']:.1f}% CPU while present "
            f"and peaked at {process['peak_cpu_pct']:.1f}%."
        )
        if name_key in KNOWN_ISSUES:
            detail += " " + KNOWN_ISSUES[name_key]
        key = ("cpu", process["pid"])
        if key not in seen_anomaly_keys:
            seen_anomaly_keys.add(key)
            anomalies.append(
                {
                    "type": "high_cpu_process",
                    "process": process["name"],
                    "pid": process["pid"],
                    "detail": detail,
                }
            )
    elif name_key in KNOWN_ISSUES and process["peak_cpu_pct"] >= 20:
        key = ("known", process["pid"])
        if key not in seen_anomaly_keys:
            seen_anomaly_keys.add(key)
            anomalies.append(
                {
                    "type": "notable_system_process",
                    "process": process["name"],
                    "pid": process["pid"],
                    "detail": KNOWN_ISSUES[name_key],
                }
            )

for process in top_ram_consumers:
    if process["peak_rss_mb"] >= 4096 and process["samples_seen"] >= max(1, actual_sample_count // 4):
        key = ("mem", process["pid"])
        if key not in seen_anomaly_keys:
            seen_anomaly_keys.add(key)
            anomalies.append(
                {
                    "type": "high_memory_process",
                    "process": process["name"],
                    "pid": process["pid"],
                    "detail": (
                        f"{process['name']} (pid {process['pid']}) peaked at "
                        f"{process['peak_rss_mb']:.0f} MB RSS."
                    ),
                }
            )

if any(level in {"warn", "critical"} for level in pressure_levels):
    anomalies.append(
        {
            "type": "memory_pressure",
            "detail": "Memory pressure reached warn/critical during the audit window.",
        }
    )

if peak(swap_used) >= 1024:
    anomalies.append(
        {
            "type": "high_swap",
            "detail": f"Swap peaked at {peak(swap_used):.0f} MB, which indicates RAM pressure or a long-lived heavy workload.",
        }
    )

if avg_total_cpu >= 80:
    anomalies.append(
        {
            "type": "sustained_high_cpu",
            "detail": f"Average total CPU stayed at {avg_total_cpu:.1f}% across the capture window.",
        }
    )

if disk_spikes:
    anomalies.append(
        {
            "type": "disk_io_spikes",
            "detail": f"Disk throughput crossed {disk_spike_threshold:.1f} MB/s {len(disk_spikes)} time(s).",
        }
    )

patterns = []
if cpu_spikes:
    patterns.append(
        f"{len(cpu_spikes)} CPU spike(s) above {cpu_spike_threshold:.1f}% total CPU."
    )
if pressure_events:
    patterns.append(
        f"{len(pressure_events)} memory-pressure event(s) reached warn/critical."
    )
if disk_spikes:
    patterns.append(
        f"{len(disk_spikes)} disk throughput spike(s) above {disk_spike_threshold:.1f} MB/s."
    )
if not patterns:
    patterns.append("No major CPU, memory-pressure, or disk I/O spikes detected in the sampled window.")

recommendations = []
if pressure_events:
    recommendations.append("Close high-memory applications first; memory pressure already reached warning or critical.")
if peak(swap_used) >= 1024:
    recommendations.append("Swap usage stayed high. Restart or close long-lived memory-heavy applications before deeper tuning.")
if any(normalize_process_name(item["name"]) == "kernel_task" for item in top_cpu_consumers[:5]):
    recommendations.append("kernel_task is prominent. Check thermals, charging state, and whether the chassis is heat-soaked.")
if any(normalize_process_name(item["name"]) == "windowserver" for item in top_cpu_consumers[:5]):
    recommendations.append("WindowServer is hot. Reduce the number of visible windows, virtual displays, and visual effects.")
if any(
    normalize_process_name(item["name"]) in {"mds", "mds_stores", "mdworker", "mdworker_shared"}
    for item in top_cpu_consumers[:10]
):
    recommendations.append("Spotlight is active. Let indexing finish or exclude very large folders if this happens repeatedly.")
if any(normalize_process_name(item["name"]) == "backupd" for item in top_cpu_consumers[:10]):
    recommendations.append("Time Machine activity is visible. Schedule backups away from interactive work if the slowdown is noticeable.")
if cpu_spikes and samples:
    leader = cpu_spikes[0]["lead_processes"][0] if cpu_spikes[0]["lead_processes"] else None
    if leader:
        recommendations.append(
            f"CPU spikes were led by {leader['name']} (pid {leader['pid']}); inspect that workload first."
        )
if avg_disk_mb_s >= 25:
    recommendations.append("Disk throughput stayed materially active. Check sync, backup, and indexing services before blaming CPU alone.")
if gpu_active_values and avg(gpu_active_values) >= 70:
    recommendations.append("GPU activity stayed high. Look for graphics-heavy apps, video processing, or external-display overhead.")
if not IS_ROOT and POWERMETRICS_AVAILABLE:
    recommendations.append("Run with sudo to include GPU power metrics: sudo ./macos-perf-audit.sh")
if not recommendations:
    recommendations.append("No major issue was captured in this 2-minute window. Re-run during a known slowdown for a more conclusive trace.")

gpu_summary = None
if gpu_power_values or gpu_active_values:
    gpu_summary = {}
    if gpu_power_values:
        gpu_summary["avg_power_mw"] = avg(gpu_power_values)
        gpu_summary["peak_power_mw"] = peak(gpu_power_values)
    if gpu_active_values:
        gpu_summary["avg_active_pct"] = avg(gpu_active_values)
        gpu_summary["peak_active_pct"] = peak(gpu_active_values)

disk_summary = {
    "avg_mb_per_sec": avg_disk_mb_s,
    "peak_mb_per_sec": peak(disk_mb_s),
    "read_delta_mb_total": round(sum(disk_read_delta), 2) if disk_read_delta else 0.0,
    "write_delta_mb_total": round(sum(disk_write_delta), 2) if disk_write_delta else 0.0,
}

meta = {
    "report_version": "2.0.0",
    "generated_at": generated_at,
    "partial_report": INTERRUPTED,
    "sampling_started_at": first_timestamp,
    "sampling_ended_at": last_timestamp,
    "hostname": hostname,
    "macos_product_name": macos_product_name,
    "macos_version": macos_version,
    "macos_version_extra": macos_version_extra or None,
    "macos_build": macos_build,
    "uptime": read_file(sys_dir / "uptime"),
    "root_disk": root_disk,
    "hardware": {
        "model": read_file(sys_dir / "model"),
        "chip": chip,
        "total_cores": int(read_file(sys_dir / "ncpu") or "0"),
        "physical_cores": int(read_file(sys_dir / "physicalcpu") or "0"),
        "performance_cores": int(read_file(sys_dir / "pcores") or "0") or None,
        "efficiency_cores": int(read_file(sys_dir / "ecores") or "0") or None,
        "memory_gb": memsize_gb,
        "gpu": gpu_info,
    },
    "sampling": {
        "interval_seconds": INTERVAL,
        "requested_duration_seconds": DURATION,
        "planned_samples": NUM_SAMPLES,
        "actual_samples": actual_sample_count,
        "top_processes_per_sample": TOP_N,
        "gpu_power_available": POWERMETRICS_AVAILABLE,
        "gpu_power_collected": bool(gpu_summary),
    },
}

summary = {
    "cpu": {
        "avg_user_pct": avg(cpu_user),
        "avg_sys_pct": avg(cpu_sys),
        "avg_total_pct": avg_total_cpu,
        "peak_user_pct": peak(cpu_user),
        "peak_sys_pct": peak(cpu_sys),
        "peak_total_pct": peak(cpu_totals),
    },
    "memory": {
        "total_gb": memsize_gb,
        "avg_used_gb": avg(memory_used),
        "peak_used_gb": peak(memory_used),
        "avg_swap_mb": avg(swap_used),
        "peak_swap_mb": peak(swap_used),
        "pressure_levels_observed": sorted(set(pressure_levels)) if pressure_levels else [],
    },
    "disk": disk_summary,
    "top_cpu_consumers": top_cpu_consumers,
    "top_ram_consumers": top_ram_consumers,
    "cpu_spikes": cpu_spikes,
    "memory_pressure_events": pressure_events,
    "disk_spikes": disk_spikes,
    "anomalies": anomalies,
    "patterns": patterns,
    "recommendations": recommendations,
}
if gpu_summary:
    summary["gpu"] = gpu_summary

report = {
    "meta": meta,
    "samples": samples,
    "summary": summary,
}

with REPORT_FILE.open("w") as handle:
    json.dump(report, handle, indent=2)

stderr = sys.stderr
print("\n╔══════════════════════════════════════════╗", file=stderr)
print("║         PERFORMANCE AUDIT SUMMARY        ║", file=stderr)
print("╚══════════════════════════════════════════╝", file=stderr)
print("", file=stderr)
print(
    f"  Hardware : {chip or 'Unknown chip'} · {memsize_gb:.1f} GB RAM · "
    f"{meta['hardware']['total_cores']} cores",
    file=stderr,
)
version_label = macos_version
if macos_version_extra:
    version_label = f"{macos_version} {macos_version_extra}".strip()
platform_label = macos_product_name or "macOS"
print(f"  macOS    : {platform_label} {version_label} ({macos_build})", file=stderr)
print(f"  Samples  : {actual_sample_count}/{NUM_SAMPLES}", file=stderr)
if INTERRUPTED:
    print("  Report   : partial (interrupted)", file=stderr)
print("", file=stderr)
print(
    f"  CPU      : avg {summary['cpu']['avg_total_pct']:.1f}% · "
    f"peak {summary['cpu']['peak_total_pct']:.1f}%",
    file=stderr,
)
print(
    f"  RAM      : avg {summary['memory']['avg_used_gb']:.1f} GB · "
    f"peak {summary['memory']['peak_used_gb']:.1f} GB / {memsize_gb:.1f} GB",
    file=stderr,
)
print(
    f"  Swap     : avg {summary['memory']['avg_swap_mb']:.0f} MB · "
    f"peak {summary['memory']['peak_swap_mb']:.0f} MB",
    file=stderr,
)
print(
    f"  Disk I/O : avg {summary['disk']['avg_mb_per_sec']:.1f} MB/s · "
    f"peak {summary['disk']['peak_mb_per_sec']:.1f} MB/s",
    file=stderr,
)
print(
    f"  Pressure : {', '.join(summary['memory']['pressure_levels_observed']) or 'unknown'}",
    file=stderr,
)
if gpu_summary:
    gpu_bits = []
    if "avg_active_pct" in gpu_summary:
        gpu_bits.append(f"active avg {gpu_summary['avg_active_pct']:.1f}%")
    if "avg_power_mw" in gpu_summary:
        gpu_bits.append(f"power avg {gpu_summary['avg_power_mw']:.0f} mW")
    print(f"  GPU      : {' · '.join(gpu_bits)}", file=stderr)

print("\n  ── Top CPU ──", file=stderr)
for process in top_cpu_consumers[:5]:
    print(
        f"    {process['name'][:28]:28s} pid {process['pid']:>6}  "
        f"avg {process['avg_cpu_pct_when_present']:6.1f}%  "
        f"peak {process['peak_cpu_pct']:6.1f}%",
        file=stderr,
    )

print("\n  ── Top RAM ──", file=stderr)
for process in top_ram_consumers[:5]:
    print(
        f"    {process['name'][:28]:28s} pid {process['pid']:>6}  "
        f"peak {process['peak_rss_mb']:8.1f} MB",
        file=stderr,
    )

if patterns:
    print("\n  ── Patterns ──", file=stderr)
    for item in patterns:
        print(f"    • {item}", file=stderr)

if anomalies:
    print(f"\n  ── Anomalies ({len(anomalies)}) ──", file=stderr)
    for anomaly in anomalies:
        print(f"    [{anomaly['type']}] {anomaly['detail']}", file=stderr)

print("\n  ── Recommendations ──", file=stderr)
for recommendation in recommendations:
    print(f"    • {recommendation}", file=stderr)
print("", file=stderr)
PYEOF
}

main() {
    parse_args "$@"
    validate_config

    echo "=== macOS Performance Audit ===" >&2
    echo "  Duration: ${DURATION}s | Interval: ${INTERVAL}s | Planned samples: ${NUM_SAMPLES}" >&2
    echo "  Top list size: ${TOP_N}" >&2
    if [ "$IS_ROOT" -eq 1 ] && [ "$POWERMETRICS_AVAILABLE" -eq 1 ]; then
        echo "  GPU power metrics: enabled" >&2
    elif [ "$POWERMETRICS_AVAILABLE" -eq 1 ]; then
        echo "  GPU power metrics: available with sudo" >&2
    else
        echo "  GPU power metrics: unavailable on this system" >&2
    fi
    echo "  Output: $(report_path)" >&2
    echo "" >&2

    collect_system_info

    for ((sample_index = 1; sample_index <= NUM_SAMPLES; sample_index++)); do
        [ "$INTERRUPTED" -eq 1 ] && break

        progress "Collecting sample ${sample_index}/${NUM_SAMPLES}..."
        local started_at ended_at elapsed remaining_sleep
        started_at=$(date +%s)

        collect_sample "$sample_index"

        ended_at=$(date +%s)
        elapsed=$((ended_at - started_at))
        remaining_sleep=$((INTERVAL - elapsed))

        if [ "$sample_index" -lt "$NUM_SAMPLES" ] && [ "$remaining_sleep" -gt 0 ] && [ "$INTERRUPTED" -eq 0 ]; then
            sleep "$remaining_sleep" &
            wait $! 2>/dev/null || true
        fi
    done

    echo "" >&2
    progress "Generating JSON report..."
    echo "" >&2

    generate_report

    echo "" >&2
    echo "Report saved to: $(report_path)" >&2
}

main "$@"
