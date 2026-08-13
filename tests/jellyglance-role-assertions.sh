#!/usr/bin/env bash
set -u

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "missing required file: $1"
    return 1
  fi
}

require_literal() {
  local description=$1 file=$2 literal=$3
  if ! grep -Fq -- "$literal" "$file"; then
    fail "$description ($file must contain: $literal)"
  fi
}

forbid_literal() {
  local description=$1 file=$2 literal=$3
  if grep -Fq -- "$literal" "$file"; then
    fail "$description ($file must not contain: $literal)"
  fi
}

require_regex() {
  local description=$1 file=$2 regex=$3
  if ! grep -Eq -- "$regex" "$file"; then
    fail "$description ($file did not match: $regex)"
  fi
}

require_count() {
  local description=$1 file=$2 literal=$3 expected=$4 actual
  actual=$(grep -Fc -- "$literal" "$file" || true)
  if [[ "$actual" -ne "$expected" ]]; then
    fail "$description (expected $expected occurrence(s), found $actual: $literal)"
  fi
}

require_before() {
  local description=$1 file=$2 first=$3 second=$4 first_line second_line
  first_line=$(grep -nF -- "$first" "$file" | head -n 1 | cut -d: -f1)
  second_line=$(grep -nF -- "$second" "$file" | head -n 1 | cut -d: -f1)
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    fail "$description (expected '$first' before '$second' in $file)"
  fi
}

registration="- { role: jellyglance, tags: ['jellyglance'] }"
registration_regex="role:[[:space:]]*(jellyglance|\"jellyglance\"|'jellyglance')([[:space:],}]|$)"

require_registration_fixture() {
  local description=$1 fixture=$2 actual
  actual=$(grep -Ec -- "$registration_regex" <<<"$fixture" || true)
  if [[ "$actual" -ne 2 ]]; then
    fail "$description registration fixture was counted as $actual instead of 2"
  fi
}

require_registration_fixture "unquoted duplicate" \
  "$registration"$'\n'"- { role: jellyglance, tags: ['duplicate'] }"
require_registration_fixture "single-quoted duplicate" \
  "$registration"$'\n'"- { role: 'jellyglance', tags: ['duplicate'] }"
require_registration_fixture "double-quoted duplicate" \
  "$registration"$'\n'"- { role: \"jellyglance\", tags: ['duplicate'] }"

registration_count=$(grep -Ec -- "$registration_regex" sandbox.yml || true)
if [[ "$registration_count" -ne 1 ]]; then
  fail "sandbox.yml must contain exactly one JellyGlance role registration (found $registration_count)"
fi
require_count "sandbox.yml must register the exact JellyGlance role once" sandbox.yml "$registration" 1
require_before "JellyGlance registration must follow Jellystat in the app list" sandbox.yml \
  "- { role: jellystat, tags: ['jellystat'] }" "$registration"

required_files=(
  roles/jellyglance/defaults/main.yml
  roles/jellyglance/tasks/main.yml
  roles/jellyglance/tasks/preflight.yml
  roles/jellyglance/tasks/secrets.yml
  roles/jellyglance/tasks/deploy.yml
  roles/jellyglance/tasks/rollback.yml
)
for file in "${required_files[@]}"; do
  require_file "$file" || true
done

defaults=roles/jellyglance/defaults/main.yml
main=roles/jellyglance/tasks/main.yml
preflight=roles/jellyglance/tasks/preflight.yml
secrets=roles/jellyglance/tasks/secrets.yml
deploy=roles/jellyglance/tasks/deploy.yml
rollback=roles/jellyglance/tasks/rollback.yml

if [[ -f "$defaults" ]]; then
  require_literal "JellyGlance must use the official GHCR image" "$defaults" \
    'jellyglance_role_docker_image_repo: "ghcr.io/nerdy-technician/jellyglance"'
  require_literal "JellyGlance must track the requested image tag" "$defaults" \
    'jellyglance_role_docker_image_tag: "latest"'
  require_literal "PostgreSQL must use the official repository" "$defaults" \
    'jellyglance_role_postgres_docker_image_repo: "postgres"'
  require_literal "PostgreSQL must use version 16 Alpine" "$defaults" \
    'jellyglance_role_postgres_docker_image_tag: "16-alpine"'
  require_literal "PostgreSQL database must be jellyglance" "$defaults" \
    'jellyglance_role_postgres_docker_env_db: "jellyglance"'
  require_literal "PostgreSQL user must be jellyglance" "$defaults" \
    'jellyglance_role_postgres_user: "jellyglance"'
  require_literal "PostgreSQL shared memory must be 1 GiB" "$defaults" \
    'jellyglance_role_postgres_docker_shm_size: "1G"'

  require_literal "config mount must use the declared path interface" "$defaults" \
    "lookup('role_var', '_paths_config_location', role='jellyglance') }}:/app/config"
  require_literal "backup mount must use the declared path interface" "$defaults" \
    "lookup('role_var', '_paths_backups_location', role='jellyglance') }}:/app/backups"

  for env_key in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_IP POSTGRES_PORT POSTGRES_DB \
    JWT_SECRET TZ CONFIG_DIR BACKUP_DIR CORS_ORIGINS; do
    require_regex "required application environment key $env_key is missing" "$defaults" \
      "^[[:space:]]+$env_key:"
    require_literal "protected environment list must include $env_key" "$defaults" \
      "- $env_key"
  done
  require_regex "POSTGRES_PORT must be 5432" "$defaults" "POSTGRES_PORT:[[:space:]]*[\"']?5432"
  require_literal "CONFIG_DIR must point at the config mount" "$defaults" 'CONFIG_DIR: "/app/config"'
  require_literal "BACKUP_DIR must point at the backups mount" "$defaults" 'BACKUP_DIR: "/app/backups"'
  require_literal "config mount target must be protected" "$defaults" '- "/app/config"'
  require_literal "backup mount target must be protected" "$defaults" '- "/app/backups"'
  require_literal "Saltbox SSO must remain disabled" "$defaults" \
    'jellyglance_role_traefik_sso_middleware: ""'
  require_literal "native health check must use the configuration endpoint" "$defaults" \
    '/auth/isConfigured'
  if grep -Eq '^jellyglance_role_postgres_deploy:' "$defaults"; then
    fail "mandatory PostgreSQL deployment must not expose a disable toggle"
  fi

  if ! python3 - "$defaults" <<'PY'
import sys
import yaml

defaults_path = sys.argv[1]

def load(path):
    with open(path, encoding="utf-8") as stream:
        value = yaml.safe_load(stream)
    return value

defaults = load(defaults_path)
if not isinstance(defaults, dict):
    raise SystemExit("role defaults YAML must contain a mapping")
if "jellyglance_role_postgres_deploy" in defaults:
    raise SystemExit("mandatory PostgreSQL deployment must not expose a disable toggle")

required_keys = {
    "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_IP", "POSTGRES_PORT",
    "POSTGRES_DB", "JWT_SECRET", "TZ", "CONFIG_DIR", "BACKUP_DIR",
    "CORS_ORIGINS",
}
env = defaults.get("jellyglance_role_docker_envs_default")
if not isinstance(env, dict) or not required_keys.issubset(env):
    raise SystemExit("required environment mapping must contain every protected key")
exact_env = {
    "POSTGRES_PORT": "5432",
    "CONFIG_DIR": "/app/config",
    "BACKUP_DIR": "/app/backups",
}
for key, expected in exact_env.items():
    if str(env.get(key)) != expected:
        raise SystemExit(f"{key} must equal {expected}")
expected_role_vars = {
    "POSTGRES_USER": "_postgres_user",
    "POSTGRES_IP": "_postgres_name",
    "POSTGRES_DB": "_postgres_docker_env_db",
    "CORS_ORIGINS": "_web_url",
}
for key, suffix in expected_role_vars.items():
    reference = f"lookup('role_var', '{suffix}', role='jellyglance')"
    if reference not in str(env.get(key, "")):
        raise SystemExit(f"{key} must be sourced from JellyGlance role_var {suffix}")
expected_refs = {
    "POSTGRES_PASSWORD": "jellyglance_postgres_password",
    "JWT_SECRET": "jellyglance_jwt_secret",
    "TZ": "tz",
}
for key, reference in expected_refs.items():
    if reference not in str(env.get(key, "")):
        raise SystemExit(f"{key} must be sourced from {reference}")

protected_env = defaults.get("jellyglance_role_docker_envs_protected")
if not isinstance(protected_env, list) or set(protected_env) != required_keys or len(protected_env) != len(required_keys):
    raise SystemExit("protected environment list must exactly mirror required environment keys")

volumes = defaults.get("jellyglance_role_docker_volumes_default")
if not isinstance(volumes, list):
    raise SystemExit("required volume mapping must be a list")
targets = {}
for volume in volumes:
    if not isinstance(volume, str) or ":" not in volume:
        raise SystemExit("required volumes must use source:target mappings")
    source, target = volume.rsplit(":", 1)
    targets[target] = source
if set(targets) != {"/app/config", "/app/backups"}:
    raise SystemExit("required volume mapping must contain exactly config and backups")
expected_volume_sources = {
    "/app/config": "{{ lookup('role_var', '_paths_config_location', role='jellyglance') }}",
    "/app/backups": "{{ lookup('role_var', '_paths_backups_location', role='jellyglance') }}",
}
if targets != expected_volume_sources:
    raise SystemExit("required volume sources must use JellyGlance role_var path interfaces")
protected_targets = defaults.get("jellyglance_role_docker_volume_targets_protected")
if not isinstance(protected_targets, list) or set(protected_targets) != {"/app/config", "/app/backups"} or len(protected_targets) != 2:
    raise SystemExit("protected volume targets must exactly mirror required mount targets")
PY
  then
    fail "YAML-aware defaults contract failed"
  fi
fi

if [[ -f "$preflight" ]]; then
  require_literal "preflight must assert protected custom environment keys" "$preflight" \
    'jellyglance_role_docker_envs_protected'
  require_literal "preflight must assert protected custom mount targets" "$preflight" \
    'jellyglance_role_docker_volume_targets_protected'
  require_literal "preflight must calculate collisions rather than silently overwrite" "$preflight" \
    'intersect'
  require_literal "preflight collision checks must fail closed" "$preflight" \
    'ansible.builtin.assert:'
  require_literal "test mode must be guarded by CI" "$preflight" 'jellyglance_test_mode'
  require_literal "test mode must require continuous integration" "$preflight" 'continuous_integration'
  require_literal "Cloudflare lookup must use the installed record parameter" "$preflight" \
    'record: "{{ lookup('\''role_var'\'', '\''_dns_record'\'', role='\''jellyglance'\'') }}.{{ lookup('\''role_var'\'', '\''_dns_zone'\'', role='\''jellyglance'\'') }}"'
  forbid_literal "Cloudflare lookup must not use the obsolete record_name parameter" "$preflight" \
    'record_name:'
  require_literal "existing secrets must validate the exact newline-bearing raw length" "$preflight" \
    'b64decode | length == 65'
  require_literal "permission repair must normalize every non-0600 mode" "$preflight" \
    "jellyglance_jwt_stat.mode != '0600'"
  require_literal "volume parsing must account for compound Docker mount suffixes" "$preflight" \
    '(?:ro|rw|z|Z)(?:,(?:ro|rw|z|Z))*'
fi

if [[ -f "$secrets" ]]; then
  require_literal "test-mode JWT initialization must use the runner interface" "$secrets" \
    'jellyglance_test_init_jwt_secret'
  require_literal "test-mode PostgreSQL initialization must use the runner interface" "$secrets" \
    'jellyglance_test_init_postgres_password'
  require_literal "secret installation must be exclusive rather than overwriting" "$secrets" \
    '/usr/bin/ln'
  forbid_literal "secret installation must not overwrite with mv" "$secrets" '/usr/bin/mv'
  require_literal "secret rollback must track per-run installed paths" "$secrets" \
    'jellyglance_installed_secret_paths'
  require_literal "secret cleanup must validate the resolved staging parent" "$secrets" \
    'jellyglance_secret_parent_resolved'
  forbid_literal "secret cleanup must not use a fixed fallback target" "$secrets" \
    '/nonexistent/jellyglance-secret-stage'
fi

if [[ -f "$main" ]]; then
  require_before "normal orchestration must preflight before secret mutation" "$main" \
    'preflight.yml' 'secrets.yml'
  require_before "normal orchestration must preflight before deployment mutation" "$main" \
    'preflight.yml' 'deploy.yml'
  require_literal "rollback-only mode must use the guarded rollback task file" "$main" \
    'rollback.yml'
  require_literal "main must expose the boolean rollback-only interface" "$main" \
    'jellyglance_rollback_only | bool'
  require_before "evidence must be prepared before preflight validation" "$main" \
    'Prepare JellyGlance evidence directory' 'preflight.yml'
fi

if [[ -f "$deploy" ]]; then
  require_literal "deployment must persist atomic mode-0600 evidence" "$deploy" \
    'mode: "0600"'
  require_literal "deployment evidence must capture the pre-existing app identity" "$deploy" \
    'preexisting_app_id'
  require_literal "deployment evidence must capture the pre-existing PostgreSQL identity" "$deploy" \
    'preexisting_postgres_id'
  require_literal "deployment evidence must track runtime-created identities" "$deploy" \
    'runtime_created'
  require_literal "DNS mutation intent must be persisted before the tasker" "$deploy" \
    'mutation_attempted'
  require_before "DNS mutation intent must precede the standard tasker" "$deploy" \
    'Persist JellyGlance DNS mutation-attempt evidence atomically' 'dns/tasker.yml'
  require_literal "DNS post-state must enforce expected cardinality" "$deploy" \
    'jellyglance_dns_expected_records | length'
  require_literal "deployment must checkpoint Jellyfin baseline 00" "$deploy" \
    '00-jellyfin-before.json'
  require_literal "deployment must checkpoint Jellyfin after healthy PostgreSQL" "$deploy" \
    '10-jellyfin-after-postgres.json'
  require_literal "deployment must checkpoint Jellyfin after healthy application" "$deploy" \
    '20-jellyfin-after-app.json'
  require_literal "deployment must use the standard DNS tasker" "$deploy" \
    'dns/tasker.yml'
  require_literal "deployment must re-query DNS through the installed module" "$deploy" \
    'cloudflare_dns_records:'
  require_literal "PostgreSQL deployment must be unconditional" "$deploy" \
    'postgres_instances:'
  require_literal "PostgreSQL deployment must use the role shm-size interface" "$deploy" \
    'postgres_role_docker_shm_size:'
fi

if [[ -f "$rollback" ]]; then
  require_literal "rollback must read persisted evidence" "$rollback" \
    'ansible.builtin.slurp:'
  require_literal "rollback must preserve application data" "$rollback" \
    'remove_docker_container.yml'
  require_literal "rollback must match pre-existing identities" "$rollback" \
    'preexisting_app_id'
  require_literal "rollback must match runtime-created identities" "$rollback" \
    'runtime_created'
  require_literal "rollback DNS deletion must be gated by creation evidence" "$rollback" \
    'dns_created_by_run'
  require_literal "rollback must support an interrupted DNS mutation attempt" "$rollback" \
    'mutation_attempted'
fi

if [[ -f "$main" && -f "$deploy" ]]; then
  if ! python3 - "$main" "$deploy" <<'PY'
import sys
import yaml

main_path, deploy_path = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as stream:
        return yaml.safe_load(stream)

main = load(main_path)
deploy = load(deploy_path)
if not isinstance(main, list) or not isinstance(deploy, list):
    raise SystemExit("role task YAML must contain task lists")

def include_value(task, module):
    value = task.get(module)
    if isinstance(value, str):
        return {"file": value}
    return value if isinstance(value, dict) else None

def flatten(tasks):
    for task in tasks:
        yield task
        for section in ("block", "rescue", "always"):
            nested = task.get(section)
            if isinstance(nested, list):
                yield from flatten(nested)

main_tasks = list(flatten(main))
deploy_tasks = list(flatten(deploy))

secret_include = next((include_value(task, "ansible.builtin.include_tasks") for task in main_tasks
                       if "secrets.yml" in str(task.get("ansible.builtin.include_tasks", ""))), None)
if not secret_include or secret_include.get("apply", {}).get("no_log") is not True:
    raise SystemExit("secrets.yml include_tasks must own apply.no_log: true")

postgres_include = next((include_value(task, "ansible.builtin.include_role") for task in deploy_tasks
                         if isinstance(task.get("ansible.builtin.include_role"), dict)
                         and task["ansible.builtin.include_role"].get("name") == "postgres"), None)
if not postgres_include or postgres_include.get("apply", {}).get("no_log") is not True:
    raise SystemExit("postgres include_role must own apply.no_log: true")

docker_include = next((include_value(task, "ansible.builtin.include_tasks") for task in deploy_tasks
                       if "create_docker_container.yml" in str(task.get("ansible.builtin.include_tasks", ""))), None)
if not docker_include or docker_include.get("apply", {}).get("no_log") is not True:
    raise SystemExit("Docker resource include_tasks must own apply.no_log: true")
PY
  then
    fail "YAML-aware include ownership contract failed"
  fi
fi

if ((failures > 0)); then
  printf 'JellyGlance static contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: JellyGlance static role contract\n'
