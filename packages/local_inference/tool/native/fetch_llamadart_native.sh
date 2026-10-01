#!/usr/bin/env bash
# Vendors the llama.cpp bundles of llamadart-native v0.4.0, the native runtime of llamadart 0.8.23, and checks every
# archive and every file it unpacks to against llamadart-native-v0.4.0.sha256. llamadart's hook checks none of them.
#
# Usage:
#   fetch_llamadart_native.sh [--dest DIR] [--verify-only] [bundle ...]
#   fetch_llamadart_native.sh --write-manifest [--dest DIR]
#
#   bundle            upstream bundle name (macos-arm64, ios-arm64-sim, ...); default: every bundle in bundles.txt
#   --dest DIR        the folder llamadart_native_path points at (default: $NATIVES_DIR/llamadart-native/v0.4.0)
#   --verify-only     check the bundles in DIR against the manifest; no network, no changes
#   --write-manifest  maintainers, for a new native version only: download every bundle in bundles.txt, check each
#                     archive against the release's SHA256SUMS, unpack, write the manifest, then install as usual
#
# DIR holds <bundle>/<release archive> and <bundle>/extracted/<what it unpacks to>, symlinks stored as copies of their
# targets as the hook's own extraction does. llamadart's hook uses <bundle>/extracted as it is (hook/build.dart
# 1544-1560, 1588-1601). extracted/target-bundle-not-vendored.so is an empty guard: a build for a bundle that is not
# in DIR fails with "No primary libllamadart library found in DIR/extracted" instead of taking other platforms'
# libraries from DIR. README.md has the details, the trust record and the update steps.
#
# A bundle is downloaded and unpacked in a temporary folder next to DIR, checked, and only then moved into DIR. A
# bundle already in DIR is skipped when it verifies, and rebuilt otherwise (from its archive when that verifies).
#
# Environment:
#   NATIVES_DIR              root of the vendored natives (default: <repo>/.natives)
#   LLAMADART_NATIVE_MIRROR  download base (default: https://github.com/leehack/llamadart-native/releases/download/v0.4.0)
#   SHA256_CMD               checksum command (default: shasum -a 256 on macOS, sha256sum elsewhere)
#
# Exit status: 0 when every requested bundle is in DIR and matches the manifest; 1 when a download, a bundle or DIR
# does not match (bad downloads are deleted; --verify-only changes nothing); 2 on a usage or environment error.
set -euo pipefail
# Bundle names are plain words; nothing below relies on globbing.
set -f

TAG=v0.4.0
LLAMADART=0.8.23
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MANIFEST="$SCRIPT_DIR/llamadart-native-$TAG.sha256"
BUNDLES_FILE="$SCRIPT_DIR/bundles.txt"
MIRROR="${LLAMADART_NATIVE_MIRROR:-https://github.com/leehack/llamadart-native/releases/download/$TAG}"
GUARD=extracted/target-bundle-not-vendored.so

die() {
  echo "fetch_llamadart_native: error: $*" >&2
  exit 2
}

say() {
  echo "fetch_llamadart_native: $*"
}

alarm() {
  echo "fetch_llamadart_native: ALARM: $*" >&2
}

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

DEST=""
MODE="fetch"
BUNDLES=""
while [ $# -gt 0 ]; do
  case "$1" in
    # --dir is accepted as another spelling of --dest.
    --dest | --dir)
      [ $# -ge 2 ] || die "$1 needs a directory"
      DEST="$2"
      shift 2
      ;;
    --dest=* | --dir=*)
      DEST="${1#*=}"
      shift
      ;;
    --verify-only | --write-manifest)
      [ "$MODE" = fetch ] || die "--verify-only and --write-manifest exclude each other"
      if [ "$1" = --verify-only ]; then MODE="verify"; else MODE="write"; fi
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option $1 (see --help)" ;;
    *)
      BUNDLES="$BUNDLES $1"
      shift
      ;;
  esac
done

[ -n "$DEST" ] || DEST="${NATIVES_DIR:-$REPO_ROOT/.natives}/llamadart-native/$TAG"
if [ "$MODE" = write ] && [ -n "$BUNDLES" ]; then
  die "--write-manifest takes no bundle names: the manifest always covers every bundle in bundles.txt"
fi
if [ -z "$BUNDLES" ]; then
  [ -f "$BUNDLES_FILE" ] || die "missing $BUNDLES_FILE"
  BUNDLES="$(awk '{ sub(/#.*/, ""); for (i = 1; i <= NF; i++) print $i }' "$BUNDLES_FILE")"
fi
[ -n "$(printf '%s' "$BUNDLES" | tr -d ' \t\n')" ] || die "no bundles given and none in $BUNDLES_FILE"
for b in $BUNDLES; do
  case "$b" in
    extracted | *[!A-Za-z0-9_-]*) die "not a bundle name: $b" ;;
  esac
done

if [ -z "${SHA256_CMD:-}" ]; then
  if [ "$(uname -s)" = Darwin ] && command -v shasum >/dev/null 2>&1; then
    SHA256_CMD="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then
    SHA256_CMD=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    SHA256_CMD="shasum -a 256"
  else
    die "needs sha256sum or shasum"
  fi
fi
command -v tar >/dev/null 2>&1 || die "needs tar"

WORK=""
cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT

sha256_of() {
  $SHA256_CMD "$1" | awk '{ print $1 }'
}

# Prints the manifest hash of path $1, or nothing.
manifest_hash() {
  awk -v p="$1" '!/^#/ && substr($0, 67) == p { print substr($0, 1, 64) }' "$MANIFEST"
}

# Prints the manifest lines of the files under folder $1.
manifest_lines() {
  awk -v p="$1/" '!/^#/ && substr($0, 67, length(p)) == p' "$MANIFEST"
}

# Checks the manifest's format, and that it has an archive for every requested bundle.
check_manifest() {
  local bad b
  [ -f "$MANIFEST" ] || die "missing $MANIFEST"
  bad="$(grep -v '^#' "$MANIFEST" | grep -Ev '^[0-9a-f]{64}  [A-Za-z0-9][A-Za-z0-9._/-]*$' || true)"
  [ -z "$bad" ] || die "malformed lines in $MANIFEST: $bad"
  bad="$(grep -v '^#' "$MANIFEST" | cut -c 67- | grep -E '(^|/)\.\.?(/|$)' || true)"
  [ -z "$bad" ] || die "paths with . or .. in $MANIFEST: $bad"
  for b in $BUNDLES; do
    [ -n "$(manifest_hash "$b/llamadart-native-$b-$TAG.tar.gz")" ] || die "$b is not in $MANIFEST"
  done
}

# Checks folder $2 under root $1 against its manifest lines: the same files, no symlinks, the same hashes.
# Prints what differs and returns 1 when anything does.
check_tree() {
  local root="$1" name="$2" lines missing extra links
  lines="$(manifest_lines "$name")"
  if [ -z "$lines" ]; then
    echo "  $name: not in the manifest"
    return 1
  fi
  if [ ! -d "$root/$name" ]; then
    echo "  $name: missing"
    return 1
  fi
  printf '%s\n' "$lines" | cut -c 67- | LC_ALL=C sort >"$WORK/expected"
  (cd "$root" && find "$name" \( -type f -o -type l \) ! -name .DS_Store) | LC_ALL=C sort >"$WORK/actual"
  missing="$(LC_ALL=C comm -23 "$WORK/expected" "$WORK/actual")"
  extra="$(LC_ALL=C comm -13 "$WORK/expected" "$WORK/actual")"
  links="$(cd "$root" && find "$name" -type l)"
  if [ -n "$missing$extra$links" ]; then
    [ -z "$missing" ] || printf '%s\n' "$missing" | sed 's/^/  missing: /'
    [ -z "$extra" ] || printf '%s\n' "$extra" | sed 's/^/  not in the manifest: /'
    [ -z "$links" ] || printf '%s\n' "$links" | sed 's/^/  symlink: /'
    return 1
  fi
  printf '%s\n' "$lines" >"$WORK/check.sha256"
  (cd "$root" && $SHA256_CMD -c --quiet "$WORK/check.sha256" 2>&1 | sed 's/^/  /')
}

# Unpacks archive $1 into the empty folder $2 the way the hook's _extractArchive does (hook/build.dart:2204-2306):
# every entry stays inside $2, and every symlink becomes a copy of the file it points to.
unpack() {
  local archive="$1" out="$2" bad link target
  tar -tzf "$archive" >"$WORK/entries" || return 1
  bad="$(grep -E '^/|(^|/)\.\.(/|$)' "$WORK/entries" || true)"
  if [ -n "$bad" ]; then
    echo "  entries outside the folder: $bad"
    return 1
  fi
  tar -x -z --no-same-owner -f "$archive" -C "$out" || return 1
  (cd "$out" && find . -type l) >"$WORK/links"
  while IFS= read -r link; do
    target="$(readlink "$out/$link")"
    case "$target" in
      /* | .. | ../* | */.. | */../*)
        echo "  symlink out of the folder: $link -> $target"
        return 1
        ;;
    esac
    if [ ! -f "$out/$link" ]; then
      echo "  symlink to no file: $link -> $target"
      return 1
    fi
  done <"$WORK/links"
  while IFS= read -r link; do
    cp "$out/$link" "$out/$link.copy" || return 1
    mv -f "$out/$link.copy" "$out/$link" || return 1
  done <"$WORK/links"
}

download() {
  command -v curl >/dev/null 2>&1 || die "needs curl"
  say "downloading $1"
  curl -fL --retry 5 --retry-delay 3 --retry-connrefused --connect-timeout 30 -sS -o "$2" "$1"
}

# Makes sure DEST holds the guard, and only the guard, in extracted/.
place_guard() {
  mkdir -p "$DEST/extracted"
  if [ ! -f "$DEST/$GUARD" ] || [ -s "$DEST/$GUARD" ]; then
    rm -f "$DEST/$GUARD"
    : >"$DEST/$GUARD"
  fi
}

# Prints the entries at the top of DEST that the manifest does not cover.
strays() {
  [ -d "$DEST" ] || return 0
  grep -v '^#' "$MANIFEST" | cut -c 67- | cut -d / -f 1 | LC_ALL=C sort -u >"$WORK/known"
  (cd "$DEST" && ls -A) | grep -vxF .DS_Store | LC_ALL=C sort >"$WORK/top" || true
  LC_ALL=C comm -13 "$WORK/known" "$WORK/top"
}

count_files() {
  printf '%s\n' "$1" | grep -c . || true
}

FAILED=""

# Puts bundle $1 into DEST, or adds it to FAILED.
fetch_bundle() {
  local b="$1" archive want got stage report
  archive="llamadart-native-$b-$TAG.tar.gz"
  want="$(manifest_hash "$b/$archive")"
  [ -n "$want" ] || die "$b is not in $MANIFEST"
  if report="$(check_tree "$DEST" "$b")"; then
    say "$b: in place and verified"
    return 0
  fi
  if [ -e "$DEST/$b" ]; then
    say "$b: does not match the manifest, rebuilding it"
    printf '%s\n' "$report"
  fi

  stage="$WORK/stage"
  rm -rf "$stage"
  mkdir -p "$stage/$b/extracted"
  if [ -f "$DEST/$b/$archive" ] && [ "$(sha256_of "$DEST/$b/$archive")" = "$want" ]; then
    say "$b: unpacking the verified $archive already in place"
    cp "$DEST/$b/$archive" "$stage/$b/$archive"
  else
    rm -f "$WORK/$archive"
    if ! download "$MIRROR/$archive" "$WORK/$archive"; then
      rm -f "$WORK/$archive"
      say "$b: download failed"
      FAILED="$FAILED $b"
      return 0
    fi
    got="$(sha256_of "$WORK/$archive")"
    if [ "$got" != "$want" ]; then
      rm -f "$WORK/$archive"
      alarm "$archive from $MIRROR has sha256 $got but the manifest says $want; deleted it"
      FAILED="$FAILED $b"
      return 0
    fi
    mv "$WORK/$archive" "$stage/$b/$archive"
  fi

  if ! report="$(unpack "$stage/$b/$archive" "$stage/$b/extracted")"; then
    printf '%s\n' "$report"
    rm -rf "$stage"
    say "$b: could not unpack $archive; deleted what was unpacked"
    FAILED="$FAILED $b"
    return 0
  fi
  # The archive matched, so a difference here comes from the local tar or the manifest, not from upstream.
  if ! report="$(check_tree "$stage" "$b")"; then
    printf '%s\n' "$report"
    rm -rf "$stage"
    say "$b: the files unpacked from $archive do not match the manifest; deleted them"
    FAILED="$FAILED $b"
    return 0
  fi
  rm -rf "${DEST:?}/$b"
  mv "$stage/$b" "$DEST/$b"
  say "$b: installed and verified (archive + $(($(count_files "$(manifest_lines "$b")") - 1)) unpacked)"
}

# Checks the guard and the top of DEST; adds to FAILED on a problem.
check_dest() {
  local report s
  if report="$(check_tree "$DEST" extracted)"; then
    say "guard $GUARD: verified"
  else
    say "guard $GUARD: FAILED"
    printf '%s\n' "$report"
    FAILED="$FAILED guard"
  fi
  s="$(strays)"
  if [ -n "$s" ]; then
    say "not covered by the manifest, and a build could use it: $(printf '%s' "$s" | tr '\n' ' ')"
    FAILED="$FAILED strays"
  fi
}

write_manifest() {
  local b archive want got n
  download "$MIRROR/SHA256SUMS" "$WORK/SHA256SUMS" || die "could not download $MIRROR/SHA256SUMS"
  say "upstream SHA256SUMS: sha256 $(sha256_of "$WORK/SHA256SUMS")"
  : >"$WORK/body"
  for b in $BUNDLES; do
    archive="llamadart-native-$b-$TAG.tar.gz"
    mkdir -p "$WORK/stage/$b/extracted"
    if ! download "$MIRROR/$archive" "$WORK/stage/$b/$archive"; then
      FAILED="$FAILED $b"
      continue
    fi
    want="$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$WORK/SHA256SUMS")"
    got="$(sha256_of "$WORK/stage/$b/$archive")"
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
      alarm "$archive has sha256 $got; SHA256SUMS says '${want:-nothing}'"
      FAILED="$FAILED $b"
      continue
    fi
    if ! unpack "$WORK/stage/$b/$archive" "$WORK/stage/$b/extracted"; then
      FAILED="$FAILED $b"
      continue
    fi
    (cd "$WORK/stage" && find "$b" -type f | LC_ALL=C sort) >"$WORK/files"
    n=0
    while IFS= read -r f; do
      (cd "$WORK/stage" && $SHA256_CMD "$f") >>"$WORK/body"
      n=$((n + 1))
    done <"$WORK/files"
    say "$b: $got, as in SHA256SUMS (archive + $((n - 1)) unpacked)"
  done
  [ -z "$FAILED" ] || {
    say "failed:$FAILED; the manifest was not written"
    exit 1
  }
  mkdir -p "$WORK/stage/extracted"
  : >"$WORK/stage/$GUARD"
  (cd "$WORK/stage" && $SHA256_CMD "$GUARD") >>"$WORK/body"
  {
    echo "# llamadart-native $TAG (https://github.com/leehack/llamadart-native), the llama.cpp runtime of llamadart $LLAMADART."
    echo "# Paths are relative to the folder llamadart_native_path points at; check it from there with"
    echo "# 'shasum -a 256 -c <this file>', or with fetch_llamadart_native.sh --verify-only. <bundle>/extracted/ holds what"
    echo "# the archive unpacks to (symlinks stored as copies); $GUARD is our empty guard file."
    echo "# Written by fetch_llamadart_native.sh --write-manifest; README.md records where each hash was checked."
    awk '{ print substr($0, 67) "\t" $0 }' "$WORK/body" | LC_ALL=C sort | cut -f 2-
  } >"$WORK/manifest"
  mv "$WORK/manifest" "$MANIFEST"
  say "wrote $MANIFEST ($(grep -vc '^#' "$MANIFEST") files); review its git diff before committing"
  check_manifest
  for b in $BUNDLES; do
    rm -rf "${DEST:?}/$b"
    mv "$WORK/stage/$b" "$DEST/$b"
  done
  place_guard
}

case "$MODE" in
  verify)
    check_manifest
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/fetch_llamadart_native.XXXXXX")"
    say "verifying $DEST"
    for b in $BUNDLES; do
      if report="$(check_tree "$DEST" "$b")"; then
        say "$b: verified (archive + $(($(count_files "$(manifest_lines "$b")") - 1)) unpacked)"
      else
        say "$b: FAILED"
        printf '%s\n' "$report"
        FAILED="$FAILED $b"
      fi
    done
    check_dest
    ;;
  fetch | write)
    [ "$MODE" = write ] || check_manifest
    mkdir -p "$DEST"
    DEST="$(cd "$DEST" && pwd)"
    WORK="$(mktemp -d "$(dirname "$DEST")/.fetch-$TAG.XXXXXX")"
    say "vendoring into $DEST"
    if [ "$MODE" = write ]; then
      write_manifest
    else
      place_guard
    fi
    for b in $BUNDLES; do
      fetch_bundle "$b"
    done
    check_dest
    ;;
esac

if [ -n "$FAILED" ]; then
  say "FAILED:$FAILED"
  exit 1
fi
say "all verified in $DEST"
