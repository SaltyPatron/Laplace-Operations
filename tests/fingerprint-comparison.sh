#!/bin/sh
# Exercise the comparison command without a database, network, or fingerprint publication.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:?set TMPDIR to build scratch}/fingerprint-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/records" "$scratch/bin"
cat > "$scratch/local.txt" <<'EOF'
machine hart-server
native 111111111111
engine 222222222222
ucd 17.0 1 abc
icu 78 unicode 17.0
resources wordnet
data wordnet 1 abc
tier0 aaa
flags bbb
highway ccc
claims wordnet 10 ddd
EOF
check(){
  expected=$1; label=$2; shift 2
  actual=0
  "$here/fingerprint.sh" compare "$scratch/local.txt" "$@" > "$scratch/output" 2>&1 || actual=$?
  if [ "$actual" != "$expected" ]; then
    cat "$scratch/output"; echo "FAIL $label: expected $expected, got $actual"; exit 1
  fi
  echo "PASS $label (exit $actual)"
}
check 2 'no peer record' "$scratch/records"
cp "$scratch/local.txt" "$scratch/records/renamed.txt"
check 2 'local record renamed is not another machine' "$scratch/records"
sed 's/hart-server/hart-desktop/' "$scratch/local.txt" > "$scratch/records/renamed.txt"
check 0 'matching peer' "$scratch/records"
sed -i 's/tier0 aaa/tier0 fff/' "$scratch/records/renamed.txt"
check 1 'different output from same inputs' "$scratch/records"
sed -i 's/111111111111/333333333333/' "$scratch/records/renamed.txt"
check 2 'different commits are not comparison evidence' "$scratch/records"
cat > "$scratch/bin/git" <<'EOF'
#!/bin/sh
exit 128
EOF
chmod +x "$scratch/bin/git"
PATH="$scratch/bin:$PATH" check 2 'record retrieval failure'
grep -q 'cannot retrieve fingerprint records' "$scratch/output"

# Run the real verification wrapper with controlled dependencies. No build, publication or database call occurs.
mkdir "$scratch/verify"
cp "$here/verify.sh" "$scratch/verify/verify.sh"
cat > "$scratch/verify/laplace.env" <<'EOF'
LAPLACE_WORK=$TEST_WORK
LAPLACE_PROGRAM=$TEST_PROGRAM
LAPLACE_TIER0=fixture-tier0
LAPLACE_UCD=fixture-ucd
EOF
cat > "$scratch/verify/seed-stamp.sh" <<'EOF'
#!/bin/sh
echo fixture-stamp
EOF
cat > "$scratch/verify/fingerprint.sh" <<'EOF'
#!/bin/sh
case $1 in
record) printf 'ucd 17.0 1 abc\nicu 78 unicode 17.0\ntier0 %s\n' "$TEST_HASH" > "$2" ;;
compare) echo 'INCOMPLETE: no other machine'; exit 2 ;;
publish) echo 'fixture publication, no network' ;;
esac
EOF
cat > "$scratch/verify/laplace" <<'EOF'
#!/bin/sh
printf 'tier 0 %s\n' "$TEST_HASH"
EOF
chmod +x "$scratch/verify/seed-stamp.sh" "$scratch/verify/fingerprint.sh" "$scratch/verify/laplace"
export TEST_WORK="$scratch/work" TEST_PROGRAM="$scratch/verify/laplace"
export TEST_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export GITHUB_STEP_SUMMARY="$scratch/summary"
actual=0
sh "$scratch/verify/verify.sh" build > "$scratch/output" 2>&1 || actual=$?
[ "$actual" = 1 ] || { cat "$scratch/output"; echo 'FAIL verification accepted missing peer evidence'; exit 1; }
grep -q 'cross-machine comparison incomplete' "$scratch/summary"
if grep -q 'a result differs\|no result differs' "$scratch/summary"; then
  cat "$scratch/summary"; echo 'FAIL fabricated comparison verdict'; exit 1
fi
echo 'PASS verification reports incomplete evidence without inventing a mismatch'
