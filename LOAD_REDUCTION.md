# Load Reduction Workflow

Use this guide when you want the lowest possible background noise before running `macos-perf-audit.sh`.

## Safe Scope

The helper script is intentionally conservative.

It can stop or disable without touching core macOS daemons:

- AdGuard app helpers
- LogiOptionsPlus helpers
- Figma
- BetterDisplay with `--extras`
- Spotlight indexing with `--spotlight`

It does not stop:

- Helium
- T3 Code
- ChatGPT Helper
- Raycast
- Arc
- Apple system daemons such as `duetexpertd`, `suggestd`, or `assistantd`

## Recommended Commands

Inspect current state first:

```bash
./trim-background-processes.sh --status
```

Preview the cleanup plan:

```bash
./trim-background-processes.sh --dry-run --spotlight --extras
```

Apply the recommended cleanup:

```bash
sudo ./trim-background-processes.sh --spotlight --extras
```

Run the audit right after cleanup:

```bash
sudo ./macos-perf-audit.sh --duration 120 --interval 5
```

## What `--spotlight` Really Does

`--spotlight` disables Spotlight indexing through `mdutil`.

This reduces indexing work, but some Spotlight-related processes may remain loaded at `0.0%` CPU. That is expected and usually not worth forcing further.

## Manual Follow-Up

If AdGuard still appears, disable its network extension manually:

`System Settings > General > Login Items & Extensions > Network Extensions`

Then re-run:

```bash
sudo ./trim-background-processes.sh --spotlight --extras
```

## Re-enable Later

To re-enable Spotlight indexing and launchd jobs disabled by the helper:

```bash
sudo ./trim-background-processes.sh --spotlight-on
```
