#!/bin/sh
# Package the built leanprof command (`lake build leanprof`) as a release
# archive: dist/leanprof-TAG-PLATFORM.tar.gz. Used by the release workflow;
# runs locally too. See RELEASING.md for the layout.
#   sh scripts/package-release.sh TAG PLATFORM      e.g. v0.1.0 macos-arm64
set -eu
tag="$1"
platform="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
test -x .lake/build/bin/leanprof || { echo "build it first: lake build leanprof" >&2; exit 1; }
name="leanprof-$tag-$platform"
dir="dist/$name"
rm -rf "$dir" "dist/$name.tar.gz"
# leanprof finds its compiler wrapper and runtime source relative to the real
# executable: <root>/.lake/build/bin/leanprof
mkdir -p "$dir/.lake/build/bin" "$dir/bin" "$dir/c" "$dir/scripts"
cp .lake/build/bin/leanprof "$dir/.lake/build/bin/"
# `leanprof elab`'s in-process frontend (exact source ranges), next to it, for
# projects on the Lean it is built with; for other Leans, `elab` builds one from
# the driver's source, which is compiled into the command (nothing else to ship)
cp .lake/build/bin/leanprof-elab-driver "$dir/.lake/build/bin/"
# `leanprof build`'s shim, which runs each toolchain program for Lake and records it
cp .lake/build/bin/leanprof-build-shim "$dir/.lake/build/bin/"
cp c/*.c c/*.h "$dir/c/"
cp scripts/leanprof-cc scripts/leanprof-tiny.awk "$dir/scripts/"
cp LICENSE README.md CHANGELOG.md "$dir/"
cat > "$dir/bin/leanprof" <<'SH'
#!/bin/sh
# launcher: follows symlinks to find the release directory
self="$0"
while [ -L "$self" ]; do
  link="$(readlink "$self")"
  case "$link" in /*) self="$link" ;; *) self="$(dirname "$self")/$link" ;; esac
done
root="$(cd "$(dirname "$self")/.." && pwd)"
exec "$root/.lake/build/bin/leanprof" "$@"
SH
chmod +x "$dir/bin/leanprof" "$dir/scripts/leanprof-cc"
tar -C dist -czf "dist/$name.tar.gz" "$name"
echo "dist/$name.tar.gz"
