from pathlib import Path
import shlex,subprocess
audit=Path(__file__).resolve().parent
archive=subprocess.run(['git','-C','Laplace-Operations','archive','HEAD'],capture_output=True,check=True).stdout
script='''set -euo pipefail
work=$(mktemp -d /repos/work/ops-accept.XXXXXX)
case "$work" in /repos/work/ops-accept.*) ;; *) exit 2 ;; esac
trap 'rm -r -- "$work"' EXIT
tar -xf - -C "$work"
cd "$work"
export TMPDIR="$work/tmp"
mkdir "$TMPDIR"
python3 tests/modular-client.py
bash tests/deployment-artifacts.sh
bash tests/deployment-readback.sh
ruby tests/deployment-workflow.rb
'''
with (audit/'operations-final-linux-acceptance.log').open('wb') as log:
 result=subprocess.run(['ssh','-o','BatchMode=yes','hart-server','bash -c '+shlex.quote(script)],input=archive,stdout=log,stderr=subprocess.STDOUT)
print((audit/'operations-final-linux-acceptance.log').read_text(encoding='utf-8',errors='replace')[-4000:])
raise SystemExit(result.returncode)
