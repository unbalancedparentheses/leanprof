#!/bin/sh
# Build leanprof's command-line tool and put a `leanprof` command on PATH.
#   sh scripts/install.sh [BIN_DIR]     (default: ~/.local/bin)
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${1:-$HOME/.local/bin}"
command -v lake >/dev/null 2>&1 || PATH="$HOME/.elan/bin:$PATH"
command -v lake >/dev/null 2>&1 || { echo "lake not found: install Lean with elan first" >&2; exit 1; }
(cd "$root" && lake build leanprof)
mkdir -p "$bin"
# a small launcher rather than a symlink: leanprof finds its scripts and
# runtime source next to the real executable
cat > "$bin/leanprof" <<SH
#!/bin/sh
exec "$root/.lake/build/bin/leanprof" "\$@"
SH
chmod +x "$bin/leanprof"
echo "installed $bin/leanprof"
case ":$PATH:" in *":$bin:"*) ;; *) echo "add $bin to your PATH" ;; esac
