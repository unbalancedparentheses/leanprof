#!/bin/sh
# Install the leanprof command.
#
# One command, no clone needed:
#   curl -sSfL https://raw.githubusercontent.com/unbalancedparentheses/leanprof/main/scripts/install.sh | sh
# downloads the prebuilt command for this platform (macOS arm64 and x86-64,
# Linux x86-64 and arm64)
# from the latest GitHub release, checked against its SHA256SUMS. When there
# is no release, none for this platform, or the binary does not run here, it
# clones the repository and builds from source (needs git and elan).
#
# From a clone, it builds that clone:
#   sh scripts/install.sh [BIN_DIR]
#
# Options (after `sh -s --` when piped):
#   --release [VERSION]  prebuilt command (default when piped), VERSION like v0.1.0
#   --source             build from source (default in a clone)
#   --bin DIR            where the `leanprof` command goes (default ~/.local/bin)
# Environment: LEANPROF_HOME (default ~/.local/share/leanprof) holds releases
# and the source checkout; LEANPROF_REPO (default
# unbalancedparentheses/leanprof); LEANPROF_DOWNLOAD overrides the download
# location (a URL or file:// directory holding the archives and SHA256SUMS).
set -eu

repo="${LEANPROF_REPO:-unbalancedparentheses/leanprof}"
home="${LEANPROF_HOME:-$HOME/.local/share/leanprof}"
bin="$HOME/.local/bin"
mode=""
version=""

here=""
case "$0" in
  */install.sh) here="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || here="" ;;
esac
[ -n "$here" ] && [ -f "$here/lakefile.lean" ] && [ -f "$here/LeanprofCli.lean" ] || here=""

while [ $# -gt 0 ]; do
  case "$1" in
    --release)
      mode=release
      case "${2:-}" in v[0-9]*) version="$2"; shift ;; esac ;;
    --source) mode=source ;;
    --bin) bin="$2"; shift ;;
    -h|--help) sed -n '2,23p' "$0" 2>/dev/null || echo "see https://github.com/$repo/blob/main/scripts/install.sh"; exit 0 ;;
    -*) echo "install.sh: unknown option $1" >&2; exit 2 ;;
    *) bin="$1" ;;
  esac
  shift
done
if [ -z "$mode" ]; then
  if [ -n "$here" ]; then mode=source; else mode=release; fi
fi

say() { echo "leanprof install: $*" >&2; }

# put a command named leanprof in $bin that runs $1: a small launcher rather
# than a symlink, since leanprof finds its scripts and runtime source next to
# the real executable
link() {
  mkdir -p "$bin"
  rm -f "$bin/leanprof"
  # single-quoted, so a path with quotes, $ or spaces cannot change the launcher
  q=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "#!/bin/sh\nexec '%s' \"\$@\"\n" "$q" > "$bin/leanprof"
  chmod +x "$bin/leanprof"
  say "installed $bin/leanprof (runs $1)"
  case ":$PATH:" in *":$bin:"*) ;; *) say "add $bin to your PATH" ;; esac
  command -v elan >/dev/null 2>&1 || [ -x "$HOME/.elan/bin/elan" ] ||
    say "leanprof needs Lean to profile anything: install elan (https://github.com/leanprover/elan)"
  command -v samply >/dev/null 2>&1 ||
    say "for 'leanprof sample', install samply (brew install samply, or cargo install samply)"
  say "check a project with: leanprof doctor"
}

platform() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo macos-arm64 ;;
    Darwin-x86_64) echo macos-x86_64 ;;
    Linux-x86_64|Linux-amd64) echo linux-x86_64 ;;
    Linux-aarch64|Linux-arm64) echo linux-arm64 ;;
    *) echo "" ;;
  esac
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() {  # URL FILE
  curl -sSfL --retry 3 -o "$2" "$1"
}

# the prebuilt command; returns 1 (and says why) when there is none to use
install_release() {
  plat="$(platform)"
  if [ -z "$plat" ]; then
    say "no prebuilt command for $(uname -s) $(uname -m)"
    return 1
  fi
  if [ -z "$version" ]; then
    if [ -n "${LEANPROF_DOWNLOAD:-}" ]; then
      say "LEANPROF_DOWNLOAD needs a version: --release vX.Y.Z"
      return 1
    fi
    # the latest release's tag, from where /releases/latest redirects to
    latest="$(curl -sSfLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" 2>/dev/null || true)"
    case "$latest" in
      */releases/tag/v*) version="${latest##*/}" ;;
      *) say "no release of $repo yet"; return 1 ;;
    esac
  fi
  base="${LEANPROF_DOWNLOAD:-https://github.com/$repo/releases/download/$version}"
  archive="leanprof-$version-$plat.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  say "downloading $archive"
  if ! fetch "$base/$archive" "$tmp/$archive" || ! fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"; then
    say "could not download $base/$archive"
    rm -rf "$tmp"
    return 1
  fi
  # exact name match (sha256sum writes "HASH  NAME", or "HASH *NAME" in binary mode)
  want="$(awk -v a="$archive" '$2 == a || $2 == "*" a { print $1; exit }' "$tmp/SHA256SUMS")"
  got="$(sha256 "$tmp/$archive")"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    say "checksum mismatch for $archive (expected ${want:-nothing}, got $got)"
    rm -rf "$tmp"
    exit 1
  fi
  mkdir -p "$home/releases"
  rm -rf "$home/releases/leanprof-$version-$plat"
  tar -C "$home/releases" -xzf "$tmp/$archive"
  rm -rf "$tmp"
  cmd="$home/releases/leanprof-$version-$plat/.lake/build/bin/leanprof"
  if ! "$cmd" help >/dev/null 2>&1; then
    say "the prebuilt command does not run here (Linux needs glibc 2.35 or newer)"
    return 1
  fi
  link "$cmd"
}

build() {  # ROOT
  command -v lake >/dev/null 2>&1 || PATH="$HOME/.elan/bin:$PATH"
  command -v lake >/dev/null 2>&1 || {
    say "building needs Lean: install elan first (https://github.com/leanprover/elan), then rerun"
    exit 1
  }
  say "building leanprof in $1"
  (cd "$1" && lake build leanprof)
  link "$1/.lake/build/bin/leanprof"
}

install_source() {
  if [ -n "$here" ]; then
    build "$here"
    return
  fi
  command -v git >/dev/null 2>&1 || { say "building from source needs git"; exit 1; }
  src="$home/src"
  if [ -d "$src/.git" ]; then
    say "updating $src"
    git -C "$src" fetch --quiet --tags origin
  else
    rm -rf "$src"
    mkdir -p "$home"
    git clone --quiet "https://github.com/$repo.git" "$src"
  fi
  if [ -n "$version" ]; then git -C "$src" checkout --quiet "$version"
  else git -C "$src" checkout --quiet origin/HEAD 2>/dev/null || git -C "$src" pull --quiet --ff-only; fi
  build "$src"
}

case "$mode" in
  release) install_release || { say "building from source instead"; install_source; } ;;
  source) install_source ;;
esac
