#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  script="$tmpdir/setup-ssh.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").fetch(0).fetch("run")' \
    "$repo_root/.github/actions/setup-ssh/action.yml" > "$script"

  setup_stub_path
  cat > "$stub_bin/ssh-keyscan" <<'STUB'
#!/usr/bin/env bash
echo "github.com ssh-ed25519 AAAAstubbedhostkey"
STUB
  cat > "$stub_bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/git-calls.txt"
STUB
  chmod +x "$stub_bin/ssh-keyscan" "$stub_bin/git"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "setup-ssh passes the key through env, not by inline interpolation" {
  action="$repo_root/.github/actions/setup-ssh/action.yml"

  run grep -Fx '        SSH_KEY: ${{ inputs.ssh-key }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F 'echo "${{ inputs.ssh-key }}"' "$action"
  [ "$status" -eq 1 ]
}

@test "setup-ssh writes the key and rewrites GitHub URLs to SSH when a key is given" {
  run env HOME="$tmpdir" SSH_KEY="private-key-content" bash "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/.ssh/id_ed25519")" = "private-key-content" ]
  [ "$(stat -c %a "$tmpdir/.ssh/id_ed25519" 2>/dev/null || stat -f %Lp "$tmpdir/.ssh/id_ed25519")" = "600" ]
  assert_contains "$(cat "$tmpdir/.ssh/known_hosts")" "github.com ssh-ed25519"
  assert_contains "$(cat "$tmpdir/git-calls.txt")" 'config --global url.git@github.com:.insteadOf https://github.com/'
}

@test "setup-ssh skips SSH setup and sends GitHub SSH URLs over HTTPS when the key is empty" {
  run env HOME="$tmpdir" SSH_KEY="" bash "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "No SSH key given"
  [ ! -e "$tmpdir/.ssh/id_ed25519" ]
  [ ! -e "$tmpdir/.ssh/known_hosts" ]

  # Terraform turns "git@github.com:org/repo" into "ssh://git@github.com/org/repo"
  # before it calls git, so both forms need a rule.
  expected_calls="config --global url.https://github.com/.insteadOf git@github.com:
config --global --add url.https://github.com/.insteadOf ssh://git@github.com/"
  [ "$(cat "$tmpdir/git-calls.txt")" = "$expected_calls" ]
}
