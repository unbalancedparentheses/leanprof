#!/bin/sh
# `leanprof elab` on a project whose Lean is not leanprof's: the first run builds
# leanprof-elab-driver for that Lean and keeps it in the cache, the next runs reuse
# it, both with exact source ranges; a driver that cannot be built falls back to
# `lean --json`, saying why. Used by CI; runs locally too:
#   sh scripts/driver-cache-check.sh LEANPROF TOOLCHAIN
# e.g. sh scripts/driver-cache-check.sh .lake/build/bin/leanprof leanprover/lean4:v4.34.1
set -eu
lp="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
toolchain="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${TMPDIR:-/tmp}/leanprof-driver-cache-$$"
rm -rf "$work"
mkdir -p "$work/project"
cp "$root"/Tests/Smoke/lakefile.toml "$root"/Tests/Smoke/lake-manifest.json "$root"/Tests/Smoke/Main.lean "$work/project/"
echo "$toolchain" > "$work/project/lean-toolchain"
cd "$work/project"
echo "== Lean: $(lake env lean --version)"
lake build > /dev/null
export LEANPROF_CACHE="$work/cache"
exact() { grep -q '"exact_ranges":true' .lake/leanprof/elab.json; }

# the driver built with leanprof, next to it: on its own Lean nothing is built
bundled="$(dirname "$lp")/leanprof-elab-driver"
if [ -x "$bundled" ] && [ "$("$bundled" --githash)" = "$(lake env lean --githash)" ]; then
  "$lp" elab Main.lean > same.txt 2> same.err
  cat same.err
  if grep -q "building" same.err; then echo "a driver was built for leanprof's own Lean"; exit 1; fi
  exact
  test ! -e "$LEANPROF_CACHE/drivers"
  cd /
  rm -rf "$work"
  echo "driver cache check passed on $toolchain (leanprof's own Lean: its driver, nothing built)"
  exit 0
fi

echo "== first run: builds the driver for this Lean"
"$lp" elab Main.lean > first.txt 2> first.err
cat first.err
grep -q "building leanprof-elab-driver for the project's Lean" first.err
grep -q "leanprof: built in" first.err
exact
grep -q '"range":"Main.lean:27:65-27:71"' .lake/leanprof/elab.json
driver="$(ls "$LEANPROF_CACHE"/drivers/*/leanprof-elab-driver)"
test "$(echo "$driver" | wc -l)" -eq 1
test "$("$driver" --githash)" = "$(lake env lean --githash)"
before="$(ls -l "$driver")"

echo "== second run: reuses it"
"$lp" elab Main.lean > second.txt 2> second.err
cat second.err
if grep -q "building" second.err; then echo "the driver was built again"; exit 1; fi
exact
test "$(ls -l "$driver")" = "$before"
test "$(ls "$LEANPROF_CACHE"/drivers | wc -l)" -eq 1

echo "== a driver that cannot be built: lean --json, and why"
touch "$work/not-a-directory"
LEANPROF_CACHE="$work/not-a-directory" "$lp" elab Main.lean > broken.txt 2> broken.err
cat broken.err
grep -q "the driver could not be built for it" broken.err
grep -q '"exact_ranges":false' .lake/leanprof/elab.json

cd /
rm -rf "$work"
echo "driver cache check passed on $toolchain"
