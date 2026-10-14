# scripts: market-recorder scripts

- `e2e-sims.sh SECONDS`: records the three simulators and exits 1 on a missing file, a stale stream, a
  raw writer failure or a failed or pending upload. CI runs it for 20 seconds.
- `e2e-rebuild.sh`: records the simulators, rebuilds the day and compares every event log byte for byte.
- `rebuild-day.sh DATA_DIR [DATE]`: wraps `rebuild-norm`; default is yesterday.
- `replicate-day.sh REMOTE_A REMOTE_B [DATE]` and `test-replicate-day.sh`: fetch two copies, merge, copy
  the result. The test runs in CI with a stand-in rclone.
- `e2e-mainnet.sh`: records real venues. It opens real connections; run it only when asked.

Rules:

- All scripts pass shellcheck, which CI runs.
- Take directories as arguments; do not hard-code paths.
