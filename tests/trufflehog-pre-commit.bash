#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/trufflehog-pre-commit.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

run_with_stub_docker() {
  local workdir="$1"
  local outdir="$2"

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

  TEST_CAPTURE_DIR="$outdir" PATH="$outdir/bin:$PATH" "$script" "$workdir"
}

# Test 1: ignored tfstate files are added to TruffleHog excludes
project="$tmpdir/project"
mkdir -p "$project"
(
  cd "$project"
  git init -q
  cat > .gitignore <<'GITIGNORE'
*.tfstate
ignored-dir/
GITIGNORE
  touch terraform.tfstate keep.txt
  mkdir -p ignored-dir
  touch ignored-dir/secret.txt
)

capture1="$tmpdir/capture1"
run_with_stub_docker "$project" "$capture1"
exclude_contents="$(cat "$capture1/exclude-file.txt")"
assert_contains "$exclude_contents" '(^|/)\.git(/|$)'
assert_contains "$exclude_contents" '(^|/)\.terraform(/|$)'
assert_contains "$exclude_contents" '(^|/)terraform\.tfstate$'
assert_contains "$exclude_contents" '(^|/)ignored-dir(/|$)'
assert_not_contains "$exclude_contents" 'keep\.txt'

# Test 2: subdirectory scans only include ignores beneath the scan dir
subproject="$tmpdir/subproject"
mkdir -p "$subproject/app"
(
  cd "$subproject"
  git init -q
  cat > .gitignore <<'GITIGNORE'
app/*.tfstate
root-only.tfstate
GITIGNORE
  touch app/terraform.tfstate root-only.tfstate
)

capture2="$tmpdir/capture2"
run_with_stub_docker "$subproject/app" "$capture2"
exclude_subdir="$(cat "$capture2/exclude-file.txt")"
assert_contains "$exclude_subdir" '(^|/)terraform\.tfstate$'
assert_not_contains "$exclude_subdir" 'root-only\.tfstate'

# Test 3: non-git directories still work with default exclusions only
plain_dir="$tmpdir/plain"
mkdir -p "$plain_dir"
capture3="$tmpdir/capture3"
run_with_stub_docker "$plain_dir" "$capture3"
exclude_plain="$(cat "$capture3/exclude-file.txt")"
assert_contains "$exclude_plain" '(^|/)\.git(/|$)'
assert_not_contains "$exclude_plain" 'terraform\.tfstate'

echo 'PASS: trufflehog-pre-commit'
