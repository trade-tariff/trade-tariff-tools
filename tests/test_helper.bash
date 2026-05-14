repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  return 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected to find [$needle] in:\n$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "did not expect to find [$needle] in:\n$haystack"
  fi
}

make_stub_docker() {
  local outdir="$1"

  mkdir -p "$outdir/bin"
  cat > "$outdir/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/docker-args.txt"
exclude_host_path=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-v" && "$arg" == *:/trufflehog-exclude-paths.txt:ro ]]; then
    exclude_host_path="${arg%%:/trufflehog-exclude-paths.txt:ro}"
    break
  fi
  prev="$arg"
done

if [[ -n "$exclude_host_path" ]]; then
  cat "$exclude_host_path" > "$TEST_CAPTURE_DIR/exclude-file.txt"
fi
STUB
  chmod +x "$outdir/bin/docker"
}

run_trufflehog_pre_commit_with_stub_docker() {
  local workdir="$1"
  local outdir="$2"

  make_stub_docker "$outdir"

  TEST_CAPTURE_DIR="$outdir" PATH="$outdir/bin:$PATH" "$repo_root/scripts/trufflehog-pre-commit.sh" "$workdir"
}

setup_stub_path() {
  stub_bin="$tmpdir/bin"
  mkdir -p "$stub_bin"
  PATH="$stub_bin:$PATH"
  export PATH stub_bin
}
