#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
artifact_root=$(mktemp -d "/tmp/jellyglance-secret-state.XXXXXX")
if [[ -z "$artifact_root" || "$artifact_root" != /tmp/jellyglance-secret-state.* || ! -d "$artifact_root" ]]; then
  printf 'FAIL: unsafe JellyGlance artifact root\n' >&2
  exit 1
fi
state_root="$artifact_root/state"
transcript="$artifact_root/ansible.log"
scan_list="$artifact_root/secret-scan-list"
fixture_vars="$artifact_root/fixture-vars.yml"
mkdir -p "$state_root"
: >"$transcript"
: >"$scan_list"
: >"$fixture_vars"
chmod 0600 "$transcript" "$scan_list" "$fixture_vars"

random_hex() {
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

fixture_names=(
  jellyglance_fixture_init_jwt_secret
  jellyglance_fixture_init_postgres_password
  jellyglance_interrupted_jwt
  jellyglance_interrupted_postgres
  jellyglance_exactly_one_fixture
  jellyglance_malformed_valid_fixture
  jellyglance_symlink_fixture
  jellyglance_mode_jwt
  jellyglance_mode_postgres
  jellyglance_collision_secret
)
for fixture_name in "${fixture_names[@]}"; do
  fixture_value=$(random_hex)
  while printf '%s\n' "$fixture_value" | grep -Fqx -f "$scan_list"; do
    fixture_value=$(random_hex)
  done
  printf '%s: "%s"\n' "$fixture_name" "$fixture_value" >>"$fixture_vars"
  printf '%s\n' "$fixture_value" >>"$scan_list"
done
printf '%s\n' 'not-a-valid-secret' >>"$scan_list"
chmod 0600 "$fixture_vars" "$scan_list"

cleanup_success() {
  [[ -n "$artifact_root" && "$artifact_root" == /tmp/jellyglance-secret-state.* ]] || return 1
  rm -rf -- "$artifact_root"
}

cleanup_failure() {
  [[ -n "$artifact_root" && "$artifact_root" == /tmp/jellyglance-secret-state.* ]] || return 1
  rm -rf -- "$state_root"
  rm -f -- "$scan_list" "$fixture_vars"
  printf 'Diagnostic transcript retained at %s\n' "$transcript" >&2
}

cleanup_leak() {
  [[ -n "$artifact_root" && "$artifact_root" == /tmp/jellyglance-secret-state.* ]] || return 1
  rm -rf -- "$artifact_root"
}

collect_scenario_secrets() {
  local file normalized
  while IFS= read -r -d '' file; do
    normalized=$(tr -d '\r\n' <"$file")
    [[ -n "$normalized" ]] || continue
    if ! printf '%s\n' "$normalized" | grep -Fqx -f "$scan_list"; then
      printf '%s\n' "$normalized" >>"$scan_list"
    fi
  done < <(find "$state_root" \( -name jwt_secret.txt -o -name postgres_password.txt \) \
    -type f -print0 2>/dev/null)
  chmod 0600 "$scan_list"
}

if [[ ! -d "$repo_root/roles/jellyglance" ]]; then
  printf 'FAIL: roles/jellyglance is required for the JellyGlance behavioral contract\n' >&2
  cleanup_success
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  printf 'FAIL: ansible-playbook is required for the JellyGlance behavioral contract\n' >&2
  cleanup_failure
  exit 1
fi

ansible_roles_path="$repo_root/roles:/srv/git/saltbox/roles:/srv/git/saltbox/resources/roles"
if [[ -n "${ANSIBLE_ROLES_PATH:-}" ]]; then
  ansible_roles_path="$ansible_roles_path:$ANSIBLE_ROLES_PATH"
fi

set +e
ANSIBLE_CONFIG="$repo_root/ansible.cfg" \
ANSIBLE_NOCOLOR=1 \
ANSIBLE_ROLES_PATH="$ansible_roles_path" \
  ansible-playbook \
  -i localhost, \
  -c local \
  "$repo_root/tests/jellyglance-secret-state.yml" \
  -e "jellyglance_test_root=$state_root" \
  -e "@$fixture_vars" \
  >"$transcript" 2>&1
playbook_status=$?
set -e

collect_scenario_secrets

if grep -Fq -f "$scan_list" "$transcript"; then
  printf 'FAIL: Ansible transcript contains a JellyGlance scenario secret\n' >&2
  cleanup_leak
  exit 1
fi

if ((playbook_status != 0)); then
  printf 'FAIL: JellyGlance behavioral contract exited %d (transcript passed secret scan)\n' \
    "$playbook_status" >&2
  cleanup_failure
  exit "$playbook_status"
fi

printf 'PASS: JellyGlance secret-state behavioral contract\n'
cleanup_success
