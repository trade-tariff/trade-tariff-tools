#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '%s\n' '[{"number":10,"updatedAt":"2026-05-01T12:00:00Z","labels":[]},{"number":11,"updatedAt":"2026-05-01T12:00:00Z","labels":[{"name":"keep"}]}]'
  exit 0
fi

echo "unexpected gh command: $*" >&2
exit 1
STUB
  chmod +x "$stub_bin/gh"
}

teardown() {
  rm -rf "$tmpdir"
}

extract_close_stale_script() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("close-stale").fetch("steps").fetch(0).fetch("run")' \
    "$repo_root/.github/workflows/close-stale-pull-requests-reusable.yml"
}

@test "close stale workflow iterates over pull requests returned by gh" {
  script="$tmpdir/close-stale.sh"
  extract_close_stale_script > "$script"

  run env \
    REPO="trade-tariff/example" \
    STALE_DAYS="14" \
    KEEP_LABEL="keep" \
    DRY_RUN="true" \
    bash "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "[DRY RUN] Would close PR #10"
  assert_contains "$output" "Skipping PR #11 (label: keep)"
  assert_contains "$output" "Summary: closed=0, skipped_keep=1, skipped_fresh=0"
}
