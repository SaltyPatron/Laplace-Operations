#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/nvidia-smi" <<'SH'
#!/bin/sh
echo 'GPU access reached on an ineligible host' >&2
touch "$GPU_PROBE_MARKER"
exit 97
SH
chmod +x "$work/bin/nvidia-smi"
printf 'LAPLACE_WORK=%s\nLAPLACE_DATA=%s\nLAPLACE_DEPS=%s\nLAPLACE_PREFIX=%s\n' \
  "$work/work" "$work/data" "$work/deps" "$work/prefix" > "$work/machine.env"
for declaration in '' another-ineligible-host; do
  env PATH="$work/bin:$PATH" GPU_PROBE_MARKER="$work/probed" SETVARS_COMPLETED=1 \
    LAPLACE_MACHINE_ENV="$work/machine.env" LAPLACE_GPU_HOST="$declaration" \
    bash "$root/chess/provision.sh" lc0 > "$work/output"
  grep -q 'skipped: GPU not authorized' "$work/output"
  test ! -e "$work/probed"
  test "$(wc -l < "$work/output")" -eq 1
done
echo 'GPU-disabled installation did not probe hardware or provision unselected tools.'
