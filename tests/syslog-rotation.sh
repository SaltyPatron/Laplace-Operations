#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?build scratch required}/syslog-rotation.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Exercise logrotate against a sparse fixture, never the host's real logs or
# rsyslog process. The configured size threshold and retention remain unchanged.
sed -e "s|^/var/log/syslog {|$work/syslog {|" \
    -e '/^    postrotate/,/^    endscript/d' \
    -e "s/create 0640 syslog adm/create 0640 $(id -un) $(id -gn)/" \
    "$root/installation/syslog.logrotate" > "$work/policy"
truncate -s 63M "$work/syslog"
logrotate --state "$work/state" "$work/policy"
[[ ! -e "$work/syslog.1" ]]
truncate -s 65M "$work/syslog"
logrotate --state "$work/state" "$work/policy"
[[ -f "$work/syslog.1" && $(stat -c %s "$work/syslog") == 0 ]]
logrotate --state "$work/state" "$work/policy"
[[ ! -e "$work/syslog.2" ]]
echo 'PASS size threshold rotates before daily interval, recreates the active log and leaves empty logs alone'
