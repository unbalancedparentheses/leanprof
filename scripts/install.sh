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
#   --samply             also fetch samply (for `leanprof sample`), without asking
#   --no-samply          do not fetch samply, and do not ask
#   --samply-only        only fetch samply (leanprof is already installed)
# When samply is not on PATH, the installer asks (on a terminal) whether to
# fetch samply 0.13.1, the release leanprof is tested with, checked against
# the SHA256 below, into LEANPROF_HOME/samply; leanprof runs that one when
# there is no samply on PATH.
# Environment: LEANPROF_HOME (default ~/.local/share/leanprof) holds releases,
# the source checkout and samply; LEANPROF_REPO (default
# unbalancedparentheses/leanprof); LEANPROF_DOWNLOAD overrides the download
# location (a URL or file:// directory holding the archives and SHA256SUMS),
# LEANPROF_SAMPLY_DOWNLOAD that of samply's archives.
set -eu

repo="${LEANPROF_REPO:-unbalancedparentheses/leanprof}"
home="${LEANPROF_HOME:-$HOME/.local/share/leanprof}"
bin="$HOME/.local/bin"
mode=""
version=""
samply=ask

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
    --samply) samply=yes ;;
    --no-samply) samply=no ;;
    --samply-only) mode=samply; samply=yes ;;
    -h|--help) sed -n '2,30p' "$0" 2>/dev/null || echo "see https://github.com/$repo/blob/main/scripts/install.sh"; exit 0 ;;
    -*) echo "install.sh: unknown option $1" >&2; exit 2 ;;
    *) bin="$1" ;;
  esac
  shift
done
if [ -z "$mode" ]; then
  if [ -n "$here" ]; then mode=source; else mode=release; fi
fi

say() { echo "leanprof install: $*" >&2; }

# samply, pinned: the release leanprof is tested with, and its archives' SHA256
samply_version=0.13.1
samply_archive() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo "aarch64-apple-darwin 7597239aa3769e75058be5ed359dbfe067f5e7714a5f052c45dd81d509aec17f" ;;
    Darwin-x86_64) echo "x86_64-apple-darwin a57f05f9162d06c36df6d51425d976ac774a8cd6dbd84050e6303fa8bf813998" ;;
    Linux-x86_64|Linux-amd64) echo "x86_64-unknown-linux-gnu 61875daad67888798690dea3cb2748279df6ac299c5c6a857d67eed7642473d9" ;;
    Linux-aarch64|Linux-arm64) echo "aarch64-unknown-linux-gnu aa465162b62830168775b7ff4804bc35049436dcbc29bb3d1ea9f580380ea06a" ;;
    *) echo "" ;;
  esac
}

# fetch samply into $home/samply; returns 1 (and says why) when it cannot
install_samply() {
  # shellcheck disable=SC2046
  set -- $(samply_archive)
  if [ $# -ne 2 ]; then
    say "no samply release for $(uname -s) $(uname -m) (https://github.com/mstange/samply)"
    return 1
  fi
  triple="$1" want="$2"
  if [ "$(uname -s)" = Linux ] && ! command -v xz >/dev/null 2>&1; then
    say "unpacking samply needs xz: sudo apt install xz-utils (or your distribution's xz package)"
    return 1
  fi
  base="${LEANPROF_SAMPLY_DOWNLOAD:-https://github.com/mstange/samply/releases/download/samply-v$samply_version}"
  archive="samply-$triple.tar.xz"
  stmp="$(mktemp -d)"
  say "downloading samply $samply_version ($archive)"
  if ! fetch "$base/$archive" "$stmp/$archive"; then
    say "could not download $base/$archive"
    rm -rf "$stmp"
    return 1
  fi
  got="$(sha256 "$stmp/$archive")"
  if [ "$got" != "$want" ]; then
    say "checksum mismatch for $archive (expected $want, got $got): not installed"
    rm -rf "$stmp"
    return 1
  fi
  tar -C "$stmp" -xJf "$stmp/$archive"
  if ! "$stmp/samply-$triple/samply" --version >/dev/null 2>&1; then
    say "the downloaded samply does not run here"
    rm -rf "$stmp"
    return 1
  fi
  mkdir -p "$home"
  rm -rf "$home/samply"
  mv "$stmp/samply-$triple" "$home/samply"
  rm -rf "$stmp"
  say "installed samply $samply_version in $home/samply (leanprof runs it when there is no samply on PATH)"
}

# samply, for `leanprof sample` and `leanprof` with no arguments: fetched with
# --samply, offered on a terminal, otherwise the command to get it is said
maybe_samply() {
  [ "$samply" = no ] && return 0
  if [ "$samply" != yes ]; then
    command -v samply >/dev/null 2>&1 && return 0
    [ -x "$home/samply/samply" ] && return 0
    if [ -t 2 ] && (: < /dev/tty) 2>/dev/null; then
      say "leanprof samples programs with samply (no rebuild), which is not installed"
      printf 'leanprof install: fetch samply %s (5 MB, checksum-verified) into %s/samply? [Y/n] ' "$samply_version" "$home" >&2
      read -r answer < /dev/tty || answer=n
      case "$answer" in [nN]*) samply=no ;; *) samply=yes ;; esac
    fi
    if [ "$samply" != yes ]; then
      say "to sample without a rebuild later: curl -sSfL https://raw.githubusercontent.com/$repo/main/scripts/install.sh | sh -s -- --samply-only"
      return 0
    fi
  fi
  install_samply || say "leanprof works without samply: then \`leanprof\` with no arguments rebuilds with probes (leanprof stat)"
}

# put a command named leanprof in $bin that runs $1: a small launcher rather
# than a symlink, since leanprof finds its scripts and runtime source next to
# the real executable
link() {
  mkdir -p "$bin"
  rm -f "$bin/leanprof"
  # single-quoted, so a path with quotes, $ or spaces cannot change the launcher
  q=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  # LEANPROF_HOME, where leanprof finds the samply this script fetched
  mkdir -p "$home"
  qh=$(cd "$home" && pwd | sed "s/'/'\\\\''/g")
  printf "#!/bin/sh\nif [ -z \"\${LEANPROF_HOME:-}\" ]; then LEANPROF_HOME='%s'; export LEANPROF_HOME; fi\nexec '%s' \"\$@\"\n" "$qh" "$q" > "$bin/leanprof"
  chmod +x "$bin/leanprof"
  say "installed $bin/leanprof (runs $1)"
  case ":$PATH:" in *":$bin:"*) ;; *) say "add $bin to your PATH" ;; esac
  command -v elan >/dev/null 2>&1 || [ -x "$HOME/.elan/bin/elan" ] ||
    say "leanprof needs Lean to profile anything: install elan (https://github.com/leanprover/elan)"
  maybe_samply
  say "then, in a Lean project: leanprof   (finds what to profile; leanprof doctor checks the setup)"
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
  samply) install_samply ;;
  release) install_release || { say "building from source instead"; install_source; } ;;
  source) install_source ;;
esac
