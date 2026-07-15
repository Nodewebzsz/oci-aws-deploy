#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_TOOL_VERSION="v0.2.0"
IMAGE_REPOSITORY="ghcr.io/nodewebzsz/oci-aws"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${OCI_AWS_INSTALL_DIR:-/opt/oci-aws}"
COMPOSE_FILE="$INSTALL_DIR/compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DATA_DIR="$INSTALL_DIR/data"
BACKUP_DIR="$INSTALL_DIR/backups"
SUMS_FILE="$INSTALL_DIR/SHA256SUMS"
PREVIOUS_FILE="$INSTALL_DIR/.previous-version"
PREVIOUS_ASSET_DIR="$INSTALL_DIR/.previous-deploy"
ASSET_DIR="$INSTALL_DIR/.deploy-assets"
ASSET_CURRENT="$ASSET_DIR/current"
DOCKER_BIN="${OCI_AWS_DOCKER_BIN:-docker}"
COPY_BIN="${OCI_AWS_COPY_BIN:-cp}"
CURL_BIN="${OCI_AWS_CURL_BIN:-curl}"
INSTALL_BIN="${OCI_AWS_INSTALL_BIN:-install}"
JQ_BIN="${OCI_AWS_JQ_BIN:-jq}"
ENV_UPDATE_BIN="${OCI_AWS_ENV_UPDATE_BIN:-awk}"
GC_BIN="${OCI_AWS_GC_BIN:-rm}"
CLEANUP_BIN="${OCI_AWS_CLEANUP_BIN:-rm}"
RELEASES_API="${OCI_AWS_RELEASES_API:-https://api.github.com/repos/Nodewebzsz/oci-aws-deploy/releases?per_page=100}"
RELEASE_DOWNLOAD_BASE="${OCI_AWS_RELEASE_DOWNLOAD_BASE:-https://github.com/Nodewebzsz/oci-aws-deploy/releases/download}"
HEALTH_TIMEOUT="${OCI_AWS_HEALTH_TIMEOUT:-90}"
PULL_TIMEOUT="${OCI_AWS_PULL_TIMEOUT:-120}"
CURL_CONNECT_TIMEOUT="${OCI_AWS_CURL_CONNECT_TIMEOUT:-10}"
CURL_TIMEOUT="${OCI_AWS_CURL_TIMEOUT:-60}"
PENDING_GENERATION=""
PENDING_GENERATION_DIR=""
PENDING_OLD_GENERATION=""
RELEASE_STAGING=""
ROLLBACK_IMAGE_SOURCE="unknown"
BACKUP_PATH=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

validate_pull_timeout() {
  [[ "$PULL_TIMEOUT" =~ ^[1-9][0-9]*$ ]]
}

require_valid_curl_timeouts() {
  [[ "$CURL_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
    || die "invalid curl connect timeout: $CURL_CONNECT_TIMEOUT"
  [[ "$CURL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
    || die "invalid curl total timeout: $CURL_TIMEOUT"
}

run_with_timeout() {
  local seconds="$1" marker pid watcher status=0
  shift
  marker="$(mktemp "${TMPDIR:-/tmp}/oci-aws-timeout.XXXXXX")" || return 125
  rm -f "$marker" || return 125
  "$@" &
  pid=$!
  (
    local timer
    trap '[[ -z "${timer:-}" ]] || kill "$timer" 2>/dev/null || true; exit 0' TERM INT
    sleep "$seconds" &
    timer=$!
    wait "$timer" || exit 0
    if kill -0 "$pid" 2>/dev/null; then
      : > "$marker" || exit 1
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) &
  watcher=$!
  wait "$pid" || status=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  if [[ -f "$marker" ]]; then
    rm -f "$marker" || true
    return 124
  fi
  rm -f "$marker" || return 125
  return "$status"
}

timed_docker_pull() {
  local image="$1" status
  if run_with_timeout "$PULL_TIMEOUT" "$DOCKER_BIN" pull "$image"; then
    return 0
  else
    status=$?
  fi
  return "$status"
}

timed_compose_pull_app() {
  local status
  if run_with_timeout "$PULL_TIMEOUT" compose pull app; then
    return 0
  else
    status=$?
  fi
  return "$status"
}

latest_stable_version() {
  command -v "$CURL_BIN" >/dev/null 2>&1 || [[ -x "$CURL_BIN" ]] || die "curl is required"
  command -v "$JQ_BIN" >/dev/null 2>&1 || [[ -x "$JQ_BIN" ]] || die "jq is required"
  local releases_file version status
  require_valid_curl_timeouts
  releases_file="$(mktemp "${TMPDIR:-/tmp}/oci-aws-releases.XXXXXX")" \
    || die "could not query public releases"
  if "$CURL_BIN" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_TIMEOUT" \
    -fsSL "$RELEASES_API" > "$releases_file" 2>/dev/null; then
    :
  else
    status=$?
    rm -f "$releases_file"
    [[ "$status" -ne 28 ]] || die "public releases request timed out"
    die "could not query public releases"
  fi
  if ! "$JQ_BIN" empty "$releases_file" >/dev/null 2>&1; then
    rm -f "$releases_file"
    die "invalid public releases response"
  fi
  if ! version="$("$JQ_BIN" -er '
    if type != "array" then error("expected releases array") else
      [
        .[]
        | select(.draft == false and .prerelease == false)
        | .tag_name as $tag
        | select($tag | test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
        | {tag: $tag, parts: ($tag[1:] | split(".") | map(tonumber))}
      ]
      | sort_by(.parts)
      | last
      | .tag // ""
    end
  ' "$releases_file" 2>/dev/null)"; then
    rm -f "$releases_file"
    die "could not evaluate public releases"
  fi
  rm -f "$releases_file"
  [[ -n "$version" ]] || die "no stable unified release is available"
  printf '%s\n' "$version"
}

hash_file() {
  local output hash
  if command -v sha256sum >/dev/null 2>&1; then
    output="$(sha256sum "$1" 2>/dev/null)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    output="$(shasum -a 256 "$1" 2>/dev/null)" || return 1
  else
    return 1
  fi
  hash="${output%% *}"
  [[ "${#hash}" -eq 64 && "$hash" != *[!0-9a-f]* ]] || return 1
  printf '%s\n' "$hash" || return 1
}

download_stable_release() {
  local version="$1" work="$2" bundle root_name root manifest_version manifest_digest
  local manifest_repository manifest_bundle expected actual name extra entry safe_entry type status
  local archive_entries archive_listing archive_types expected_entries expected_entries_unsorted
  local expected_inner expected_inner_unsorted seen_bundle=0 seen_manifest=0 inner_count=0 outer_count=0
  [[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "invalid stable version: $version"
  [[ -d "$work" ]] || die "release staging directory is missing"
  require_valid_curl_timeouts
  command -v "$CURL_BIN" >/dev/null 2>&1 || [[ -x "$CURL_BIN" ]] || die "curl is required"
  command -v "$JQ_BIN" >/dev/null 2>&1 || [[ -x "$JQ_BIN" ]] || die "jq is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"

  bundle="oci-aws-$version-deploy.tar.gz"
  for name in "$bundle" release-manifest.json SHA256SUMS; do
    if "$CURL_BIN" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_TIMEOUT" \
      -fsSL "$RELEASE_DOWNLOAD_BASE/$version/$name" -o "$work/$name" 2>/dev/null; then
      :
    else
      status=$?
      [[ "$status" -ne 28 ]] || die "release download timed out: $name"
      die "could not download $name"
    fi
  done

  while IFS=$' \t' read -r expected name extra; do
    outer_count=$((outer_count + 1))
    [[ "${#expected}" -eq 64 && "$expected" != *[!0-9a-f]* && -z "${extra:-}" ]] \
      || die "invalid outer checksum manifest"
    case "$name" in
      "$bundle")
        (( seen_bundle == 0 )) || die "unexpected outer checksum path"
        seen_bundle=1
        ;;
      release-manifest.json)
        (( seen_manifest == 0 )) || die "unexpected outer checksum path"
        seen_manifest=1
        ;;
      *) die "unexpected outer checksum path" ;;
    esac
    actual="$(hash_file "$work/$name")" || die "could not hash $name"
    [[ "$actual" == "$expected" ]] || die "$name checksum verification failed"
  done < "$work/SHA256SUMS"
  [[ "$outer_count" -eq 2 && "$seen_bundle" -eq 1 && "$seen_manifest" -eq 1 ]] \
    || die "outer checksum manifest is incomplete"

  manifest_version="$("$JQ_BIN" -er '.version | strings' "$work/release-manifest.json" 2>/dev/null)" \
    || die "release manifest is invalid"
  manifest_digest="$("$JQ_BIN" -er '.image.digest | strings' "$work/release-manifest.json" 2>/dev/null)" \
    || die "release manifest is invalid"
  manifest_repository="$("$JQ_BIN" -er '.image.repository | strings' "$work/release-manifest.json" 2>/dev/null)" \
    || die "release manifest is invalid"
  manifest_bundle="$("$JQ_BIN" -er '.bundle | strings' "$work/release-manifest.json" 2>/dev/null)" \
    || die "release manifest is invalid"
  [[ "$manifest_version" == "$version" ]] || die "manifest version mismatch"
  [[ "$manifest_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "manifest digest is invalid"
  [[ "$manifest_repository" == "$IMAGE_REPOSITORY" && "$manifest_bundle" == "$bundle" ]] \
    || die "manifest release contract mismatch"

  root_name="oci-aws-$version"
  archive_entries="$work/archive-entries"
  archive_listing="$work/archive-listing"
  archive_types="$work/archive-types"
  expected_entries_unsorted="$work/expected-entries.unsorted"
  expected_entries="$work/expected-entries"
  tar -tzf "$work/$bundle" > "$archive_entries" 2>/dev/null || die "release archive is invalid"
  tar -tvzf "$work/$bundle" > "$archive_listing" 2>/dev/null || die "release archive is invalid"
  awk '{ print substr($1, 1, 1) }' "$archive_listing" > "$archive_types" \
    || die "release archive is invalid"
  while IFS= read -r entry; do
    safe_entry="${entry%/}"
    [[ -n "$safe_entry" ]] || die "unsafe archive path"
    case "/$safe_entry/" in
      *"/../"*|*"/./"*|*"//"*) die "unsafe archive path" ;;
    esac
    [[ "$entry" != /* ]] || die "unsafe archive path"
  done < "$archive_entries"
  printf '%s\n' \
    "$root_name/" \
    "$root_name/.env.example" \
    "$root_name/.gitignore" \
    "$root_name/LICENSE" \
    "$root_name/README.md" \
    "$root_name/SHA256SUMS" \
    "$root_name/compose.yml" \
    "$root_name/oci-aws.sh" > "$expected_entries_unsorted" \
    || die "could not build expected archive paths"
  LC_ALL=C sort "$expected_entries_unsorted" -o "$expected_entries" \
    || die "could not sort expected archive paths"
  LC_ALL=C sort "$archive_entries" -o "$archive_entries.sorted" \
    || die "could not sort archive paths"
  cmp -s "$expected_entries" "$archive_entries.sorted" || die "unexpected archive path"

  exec 3< "$archive_types" || die "could not read archive entry types"
  exec 4< "$archive_entries" || die "could not read archive paths"
  while IFS= read -r type <&3; do
    if ! IFS= read -r entry <&4; then
      exec 3<&-
      exec 4<&-
      die "release archive is invalid"
    fi
    if [[ "$entry" == "$root_name/" ]]; then
      [[ "$type" == "d" ]] || { exec 3<&-; exec 4<&-; die "unsafe archive entry type"; }
    else
      [[ "$type" == "-" ]] || { exec 3<&-; exec 4<&-; die "unsafe archive entry type"; }
    fi
  done
  if IFS= read -r entry <&4; then
    exec 3<&-
    exec 4<&-
    die "release archive is invalid"
  fi
  exec 3<&- || die "could not close archive entry types"
  exec 4<&- || die "could not close archive paths"

  tar -xzf "$work/$bundle" -C "$work" 2>/dev/null || die "could not extract release archive"
  root="$work/$root_name"
  [[ -d "$root" && ! -L "$root" && -f "$root/SHA256SUMS" && ! -L "$root/SHA256SUMS" ]] \
    || die "release root is missing"
  expected_inner_unsorted="$work/expected-inner.unsorted"
  expected_inner="$work/expected-inner"
  printf '%s\n' .env.example .gitignore LICENSE README.md compose.yml oci-aws.sh \
    > "$expected_inner_unsorted" || die "could not build expected inner paths"
  LC_ALL=C sort "$expected_inner_unsorted" -o "$expected_inner" \
    || die "could not sort expected inner paths"
  : > "$work/inner-names" || die "could not stage inner checksum names"
  while IFS=$' \t' read -r expected name extra; do
    inner_count=$((inner_count + 1))
    [[ "${#expected}" -eq 64 && "$expected" != *[!0-9a-f]* && -z "${extra:-}" ]] \
      || die "inner release checksum failed"
    case "$name" in
      .env.example|.gitignore|LICENSE|README.md|compose.yml|oci-aws.sh) ;;
      *) die "inner release checksum failed" ;;
    esac
    printf '%s\n' "$name" >> "$work/inner-names" || die "could not stage inner checksum name"
    [[ -f "$root/$name" && ! -L "$root/$name" ]] || die "inner release checksum failed"
    actual="$(hash_file "$root/$name")" || die "inner release checksum failed"
    [[ "$actual" == "$expected" ]] || die "inner release checksum failed"
  done < "$root/SHA256SUMS"
  LC_ALL=C sort "$work/inner-names" -o "$work/inner-names.sorted" \
    || die "could not sort inner checksum names"
  [[ "$inner_count" -eq 6 ]] || die "inner release checksum failed"
  cmp -s "$expected_inner" "$work/inner-names.sorted" || die "inner release checksum failed"
  printf '%s\n' "$manifest_digest" > "$work/manifest-digest" \
    || die "could not stage manifest digest"
}

verify_release_assets() {
  local sums="$SCRIPT_DIR/SHA256SUMS" asset expected actual
  [[ -f "$sums" ]] || die "SHA256SUMS is missing; download the complete immutable release"
  for asset in oci-aws.sh compose.yml; do
    expected="$(awk -v name="$asset" '$2 == name { print $1; exit }' "$sums")"
    [[ -n "$expected" ]] || die "SHA256SUMS does not contain $asset"
    actual="$(hash_file "$SCRIPT_DIR/$asset")" || die "could not hash $asset"
    [[ "$actual" == "$expected" ]] || die "$asset checksum verification failed"
  done
}

require_docker() {
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || [[ -x "$DOCKER_BIN" ]] || die "Docker was not found"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is required"
}

compose() {
  "$DOCKER_BIN" compose \
    --project-directory "$INSTALL_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

env_value() {
  local key="$1" fallback="$2" value
  value="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE" 2>/dev/null || true)"
  printf '%s\n' "${value:-$fallback}"
}

set_env_value() {
  local key="$1" value="$2" destination="$ENV_FILE" tmp
  if [[ -L "$ENV_FILE" ]] && [[ "$(readlink "$ENV_FILE")" == ".deploy-assets/current/.env" ]]; then
    destination="$ASSET_CURRENT/.env"
  fi
  tmp="$ASSET_DIR/.env.tmp.$$"
  render_env_value "$ENV_FILE" "$tmp" "$key" "$value" || return 1
  mv "$tmp" "$destination" || { rm -f "$tmp" || true; return 1; }
}

render_env_value() {
  local source="$1" destination="$2" key="$3" value="$4"
  if ! "$ENV_UPDATE_BIN" -F= -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$source" > "$destination"; then
    rm -f "$destination" || true
    return 1
  fi
  chmod 600 "$destination" || { rm -f "$destination" || true; return 1; }
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

runtime_uid() {
  if (( EUID == 0 )); then printf '1001\n'; else id -u; fi
}

runtime_gid() {
  if (( EUID == 0 )); then printf '1001\n'; else id -g; fi
}

prepare_state_directories() {
  mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$BACKUP_DIR" \
    || die "cannot create $INSTALL_DIR; use sudo or set OCI_AWS_INSTALL_DIR"
  if (( EUID == 0 )); then
    chown 1001:1001 "$DATA_DIR"
  else
    [[ -O "$DATA_DIR" ]] || die "$DATA_DIR is not owned by the current user"
  fi
  chmod 700 "$DATA_DIR" "$BACKUP_DIR"
}

create_env_once() {
  [[ -f "$ENV_FILE" ]] && return
  [[ "$DEPLOY_TOOL_VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "install from an immutable unified Release bundle"
  umask 077
  cat > "$ENV_FILE" <<EOF
OCI_AWS_VERSION=$DEPLOY_TOOL_VERSION
PORT=18168
AUTH_COOKIE_SECURE=false
OCI_AWS_RUNTIME_UID=$(runtime_uid)
OCI_AWS_RUNTIME_GID=$(runtime_gid)
OCI_AWS_SECRET_KEY=$(generate_secret)
EOF
  chmod 600 "$ENV_FILE"
}

require_secret() {
  [[ -n "$(env_value OCI_AWS_SECRET_KEY "")" ]] \
    || die "OCI_AWS_SECRET_KEY is missing; refusing to start"
}

require_installed() {
  [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || die "not installed; run install first"
  require_secret
}

wait_healthy() {
  local started="$SECONDS" container status
  while (( SECONDS - started < HEALTH_TIMEOUT )); do
    container="$(compose ps -q app 2>/dev/null || true)"
    if [[ -n "$container" ]]; then
      status="$("$DOCKER_BIN" inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || true)"
      [[ "$status" == "healthy" || "$status" == "running" ]] && return 0
    fi
    sleep 2
  done
  return 1
}

print_running_version() {
  local container version image_id digest
  container="$(compose ps -q app)"
  [[ -n "$container" ]] || die "application container is not running"
  version="$("$DOCKER_BIN" inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$container")"
  image_id="$("$DOCKER_BIN" inspect --format '{{.Image}}' "$container")"
  digest="$("$DOCKER_BIN" image inspect --format '{{index .RepoDigests 0}}' "$image_id")"
  printf 'tool=%s version=%s digest=%s\n' "$DEPLOY_TOOL_VERSION" "$version" "$digest"
}

current_container() {
  compose ps -q app
}

atomic_replace_path() {
  local source="$1" destination="$2"
  if mv --version >/dev/null 2>&1; then
    mv -Tf "$source" "$destination" || return 1
  else
    mv -fh "$source" "$destination" || return 1
  fi
}

asset_current_generation() {
  local generation
  [[ -L "$ASSET_CURRENT" ]] || return 1
  generation="$(readlink "$ASSET_CURRENT")" || return 1
  [[ "$generation" =~ ^generation-[0-9]+-[0-9]+$ ]] || return 1
  [[ -d "$ASSET_DIR/$generation" ]] || return 1
  printf '%s\n' "$generation" || return 1
}

prepare_asset_generation() {
  local source_root="$1" env_source="${2:-$ENV_FILE}" generation generation_dir
  mkdir -p "$ASSET_DIR" || return 1
  chmod 755 "$ASSET_DIR" || return 1
  generation="generation-$$-${RANDOM:-0}"
  generation_dir="$ASSET_DIR/$generation"
  mkdir "$generation_dir" || return 1
  chmod 755 "$generation_dir" || { rm -rf "$generation_dir" || true; return 1; }
  "$INSTALL_BIN" -m 0755 "$source_root/oci-aws.sh" "$generation_dir/oci-aws.sh" \
    || { rm -rf "$generation_dir" || true; return 1; }
  "$INSTALL_BIN" -m 0644 "$source_root/compose.yml" "$generation_dir/compose.yml" \
    || { rm -rf "$generation_dir" || true; return 1; }
  "$INSTALL_BIN" -m 0644 "$source_root/SHA256SUMS" "$generation_dir/SHA256SUMS" \
    || { rm -rf "$generation_dir" || true; return 1; }
  "$INSTALL_BIN" -m 0600 "$env_source" "$generation_dir/.env" \
    || { rm -rf "$generation_dir" || true; return 1; }
  printf '%s\n' "$generation" || { rm -rf "$generation_dir" || true; return 1; }
}

switch_asset_generation() {
  local generation="$1" candidate="$ASSET_DIR/.current.$$-${RANDOM:-0}"
  [[ "$generation" =~ ^generation-[0-9]+-[0-9]+$ ]] || return 1
  [[ -d "$ASSET_DIR/$generation" ]] || return 1
  ln -s "$generation" "$candidate" || return 1
  atomic_replace_path "$candidate" "$ASSET_CURRENT" \
    || { rm -f "$candidate" || true; return 1; }
}

install_visible_asset_links() {
  local name visible candidate target
  for name in oci-aws.sh compose.yml SHA256SUMS .env; do
    visible="$INSTALL_DIR/$name"
    target=".deploy-assets/current/$name"
    if [[ -L "$visible" ]] && [[ "$(readlink "$visible")" == "$target" ]]; then
      continue
    fi
    candidate="$INSTALL_DIR/.$name.link.$$-${RANDOM:-0}"
    ln -s "$target" "$candidate" || return 1
    atomic_replace_path "$candidate" "$visible" \
      || { rm -f "$candidate" || true; return 1; }
  done
}

ensure_asset_layout() {
  local generation migrated_generation existing=0 name
  mkdir -p "$ASSET_DIR" || return 1
  chmod 755 "$ASSET_DIR" || return 1
  if generation="$(asset_current_generation)"; then
    for name in oci-aws.sh compose.yml SHA256SUMS; do
      [[ -f "$ASSET_DIR/$generation/$name" ]] || return 1
    done
    if [[ ! -f "$ASSET_DIR/$generation/.env" ]]; then
      [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || return 1
      migrated_generation="$(prepare_asset_generation "$ASSET_DIR/$generation" "$ENV_FILE")" \
        || return 1
      switch_asset_generation "$migrated_generation" \
        || { rm -rf "$ASSET_DIR/$migrated_generation" || true; return 1; }
    fi
    install_visible_asset_links || return 1
    return 0
  fi
  [[ ! -e "$ASSET_CURRENT" && ! -L "$ASSET_CURRENT" ]] || return 1
  for name in oci-aws.sh compose.yml SHA256SUMS; do
    [[ -e "$INSTALL_DIR/$name" || -L "$INSTALL_DIR/$name" ]] && existing=$((existing + 1))
  done
  [[ "$existing" -eq 0 ]] && return 0
  [[ "$existing" -eq 3 ]] || return 1
  [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || return 1
  generation="$(prepare_asset_generation "$INSTALL_DIR" "$ENV_FILE")" || return 1
  switch_asset_generation "$generation" \
    || { rm -rf "$ASSET_DIR/$generation" || true; return 1; }
  install_visible_asset_links || return 1
}

replace_deployment_assets() {
  local source_root="$1" env_source="${2:-$ENV_FILE}" generation
  ensure_asset_layout || return 1
  generation="$(prepare_asset_generation "$source_root" "$env_source")" || return 1
  switch_asset_generation "$generation" \
    || { rm -rf "$ASSET_DIR/$generation" || true; return 1; }
  install_visible_asset_links || return 1
}

install_staged_assets() {
  replace_deployment_assets "$1" "$2" || return 1
}

restore_previous_assets() {
  local generation_dir="$1"
  [[ -d "$generation_dir" ]] || return 1
  [[ -f "$generation_dir/.env" && ! -L "$generation_dir/.env" ]] || return 1
  replace_deployment_assets "$generation_dir" "$generation_dir/.env" || return 1
}

previous_value() {
  local key="$1" file="${2:-$PREVIOUS_FILE}"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

pending_generation_is_published() {
  local published metadata
  [[ "$PENDING_GENERATION" =~ ^generation-[0-9]+-[0-9]+$ ]] || return 1
  [[ -f "$PREVIOUS_FILE" && -d "$PENDING_GENERATION_DIR" ]] || return 1
  published="$(previous_value OCI_AWS_PREVIOUS_GENERATION)" || return 1
  [[ "$published" == "$PENDING_GENERATION" ]] || return 1
  metadata="$PENDING_GENERATION_DIR/metadata"
  [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
  cmp -s "$PREVIOUS_FILE" "$metadata" || return 1
}

discard_pending_generation() {
  if pending_generation_is_published; then
    PENDING_GENERATION=""
    PENDING_GENERATION_DIR=""
    PENDING_OLD_GENERATION=""
    return 0
  fi
  if [[ -n "$PENDING_GENERATION_DIR" ]]; then
    rm -rf "$PENDING_GENERATION_DIR" || return 1
  fi
  PENDING_GENERATION=""
  PENDING_GENERATION_DIR=""
  PENDING_OLD_GENERATION=""
}

prepare_previous_generation() {
  local assets="$1" container revision short image_id digest selection generation
  local generation_pending generation_dir metadata pointer_candidate rollback_env
  discard_pending_generation || return 1
  [[ "$assets" == "stored" || "$assets" == "unchanged" ]] || return 1
  container="$(current_container)" || return 1
  [[ -n "$container" ]] || return 1
  revision="$("$DOCKER_BIN" inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$container")" || return 1
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  short="${revision:0:7}"
  image_id="$("$DOCKER_BIN" inspect --format '{{.Image}}' "$container")" || return 1
  digest="$("$DOCKER_BIN" image inspect --format '{{index .RepoDigests 0}}' "$image_id")" || return 1
  [[ "$digest" =~ ^ghcr\.io/nodewebzsz/oci-aws@sha256:[0-9a-f]{64}$ ]] || return 1
  selection="$(env_value OCI_AWS_VERSION latest)" || return 1
  PENDING_OLD_GENERATION="$(previous_value OCI_AWS_PREVIOUS_GENERATION 2>/dev/null || true)"

  umask 077
  mkdir -p "$PREVIOUS_ASSET_DIR" || return 1
  chmod 700 "$PREVIOUS_ASSET_DIR" || return 1
  generation="generation-$$-${RANDOM:-0}"
  generation_pending="$PREVIOUS_ASSET_DIR/.$generation.pending"
  generation_dir="$PREVIOUS_ASSET_DIR/$generation"
  metadata="$generation_pending/metadata"
  pointer_candidate="$generation_pending/pointer"
  rollback_env="$generation_pending/.env"
  mkdir "$generation_pending" || return 1
  if [[ -e "$generation_dir" || -L "$generation_dir" ]]; then
    rm -rf "$generation_pending" || return 1
    return 1
  fi
  if [[ "$assets" == "stored" ]]; then
    "$INSTALL_BIN" -m 0755 "$INSTALL_DIR/oci-aws.sh" "$generation_pending/oci-aws.sh" \
      || { rm -rf "$generation_pending" || true; return 1; }
    "$INSTALL_BIN" -m 0644 "$COMPOSE_FILE" "$generation_pending/compose.yml" \
      || { rm -rf "$generation_pending" || true; return 1; }
    "$INSTALL_BIN" -m 0644 "$SUMS_FILE" "$generation_pending/SHA256SUMS" \
      || { rm -rf "$generation_pending" || true; return 1; }
  fi
  awk -F= -v value="sha-$short" '
    BEGIN { found = 0 }
    $1 == "OCI_AWS_VERSION" { print "OCI_AWS_VERSION=" value; found = 1; next }
    { print }
    END { if (!found) print "OCI_AWS_VERSION=" value }
  ' "$ENV_FILE" > "$rollback_env" \
    || { rm -rf "$generation_pending" || true; return 1; }
  chmod 600 "$rollback_env" || { rm -rf "$generation_pending" || true; return 1; }
  printf '%s\n' \
    "OCI_AWS_PREVIOUS_GENERATION=$generation" \
    "OCI_AWS_PREVIOUS_VERSION=sha-$short" \
    "OCI_AWS_PREVIOUS_DIGEST=$digest" \
    "OCI_AWS_PREVIOUS_SELECTION=$selection" \
    "OCI_AWS_PREVIOUS_ASSETS=$assets" > "$metadata" \
    || { rm -rf "$generation_pending" || true; return 1; }
  chmod 600 "$metadata" || { rm -rf "$generation_pending" || true; return 1; }
  "$INSTALL_BIN" -m 0600 "$metadata" "$pointer_candidate" \
    || { rm -rf "$generation_pending" || true; return 1; }
  PENDING_GENERATION="$generation"
  PENDING_GENERATION_DIR="$generation_pending"
}

publish_pending_generation() {
  local final_dir pending_name pointer_tmp old_generation="$PENDING_OLD_GENERATION"
  [[ "$PENDING_GENERATION" =~ ^generation-[0-9]+-[0-9]+$ ]] || return 1
  [[ -d "$PENDING_GENERATION_DIR" ]] || return 1
  final_dir="$PREVIOUS_ASSET_DIR/$PENDING_GENERATION"
  [[ ! -e "$final_dir" && ! -L "$final_dir" ]] || return 1
  pointer_tmp="$PREVIOUS_FILE.tmp.$$"
  rm -f "$pointer_tmp" || return 1
  "$INSTALL_BIN" -m 0600 "$PENDING_GENERATION_DIR/pointer" "$pointer_tmp" \
    || { rm -f "$pointer_tmp" || true; return 1; }
  rm -f "$PENDING_GENERATION_DIR/pointer" \
    || { rm -f "$pointer_tmp" || true; return 1; }
  pending_name="${PENDING_GENERATION_DIR##*/}"
  mv "$PENDING_GENERATION_DIR" "$final_dir" \
    || { rm -f "$pointer_tmp" || true; return 1; }
  if [[ -d "$final_dir/$pending_name" ]]; then
    PENDING_GENERATION_DIR="$final_dir/$pending_name"
    rm -f "$pointer_tmp" || true
    return 1
  fi
  PENDING_GENERATION_DIR="$final_dir"
  if ! mv "$pointer_tmp" "$PREVIOUS_FILE"; then
    rm -f "$pointer_tmp" || true
    return 1
  fi
  PENDING_GENERATION=""
  PENDING_GENERATION_DIR=""
  PENDING_OLD_GENERATION=""
  if [[ "$old_generation" =~ ^generation-[0-9]+-[0-9]+$ ]]; then
    "$GC_BIN" -rf "$PREVIOUS_ASSET_DIR/$old_generation" || true
  fi
}

backup_database() {
  local restart_after="${1:-yes}" emit_result="${2:-yes}" database="$DATA_DIR/oci-aws.sqlite" backup
  BACKUP_PATH=""
  [[ -f "$database" ]] || die "database not found: $database"
  compose stop app || die "could not stop the application; backup was not created"
  backup="$BACKUP_DIR/oci-aws.sqlite.$(date -u +%Y%m%dT%H%M%SZ).$$.bak"
  if ! "$COPY_BIN" "$database" "$backup" || [[ ! -s "$backup" ]]; then
    rm -f "$backup" || return 1
    if [[ "$restart_after" == "yes" ]]; then
      compose up --pull never -d app && wait_healthy \
        || die "backup failed and the original image could not be restarted"
      die "database backup failed; the original image was restarted"
    fi
    return 1
  fi
  if [[ "$restart_after" == "yes" ]]; then
    compose up --pull never -d app || die "backup completed but the original image did not start"
    wait_healthy || die "backup completed but the original image failed its health check"
  fi
  BACKUP_PATH="$backup"
  if [[ "$emit_result" == "yes" ]]; then
    printf '%s\n' "$backup"
  fi
  printf 'store OCI_AWS_SECRET_KEY separately from the database backup\n' >&2
}

rollback_generation() {
  local generation_dir="$1" verify_pointer="$2" metadata version digest assets image_id rollback_env status
  ROLLBACK_IMAGE_SOURCE="unknown"
  metadata="$generation_dir/metadata"
  rollback_env="$generation_dir/.env"
  [[ -f "$metadata" && ! -L "$metadata" ]] || {
    printf 'rollback generation metadata is missing\n' >&2
    return 1
  }
  if [[ "$verify_pointer" == "yes" ]] && ! cmp -s "$PREVIOUS_FILE" "$metadata"; then
    printf 'rollback generation metadata does not match its pointer\n' >&2
    return 1
  fi
  version="$(previous_value OCI_AWS_PREVIOUS_VERSION "$metadata")" || return 1
  digest="$(previous_value OCI_AWS_PREVIOUS_DIGEST "$metadata")" || return 1
  assets="$(previous_value OCI_AWS_PREVIOUS_ASSETS "$metadata")" || return 1
  [[ "$version" =~ ^sha-[0-9a-f]{7}$ ]] || {
    printf 'rollback record does not contain an immutable sha tag\n' >&2
    return 1
  }
  [[ "$digest" =~ ^ghcr\.io/nodewebzsz/oci-aws@sha256:[0-9a-f]{64}$ ]] || {
    printf 'rollback record does not contain a valid digest\n' >&2
    return 1
  }
  [[ "$assets" == "stored" || "$assets" == "unchanged" ]] || {
    printf 'rollback record does not contain a valid asset state\n' >&2
    return 1
  }
  if ! image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$digest" 2>/dev/null)"; then
    ROLLBACK_IMAGE_SOURCE="pull"
    if timed_docker_pull "$digest"; then
      :
    else
      status=$?
      if [[ "$status" -eq 124 ]]; then
        printf 'rollback image pull timed out after %s seconds\n' "$PULL_TIMEOUT" >&2
      fi
      return 1
    fi
    image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$digest")" || return 1
  fi
  ROLLBACK_IMAGE_SOURCE="local"
  "$DOCKER_BIN" tag "$image_id" "$IMAGE_REPOSITORY:$version" || return 1
  if [[ -f "$rollback_env" && ! -L "$rollback_env" ]]; then
    if [[ "$assets" == "stored" ]]; then
      restore_previous_assets "$generation_dir" || return 1
    else
      replace_deployment_assets "$ASSET_CURRENT" "$rollback_env" || return 1
    fi
  elif [[ "$verify_pointer" == "yes" ]]; then
    set_env_value OCI_AWS_VERSION "$version" || return 1
  else
    return 1
  fi
  compose up --pull never -d app || return 1
  wait_healthy || return 1
  printf 'rolled_back_to=%s digest=%s database=unchanged\n' "$version" "$digest"
}

rollback_pending_generation() {
  [[ -n "$PENDING_GENERATION_DIR" ]] || return 1
  rollback_generation "$PENDING_GENERATION_DIR" no || return 1
}

die_pending_recovery_failed() {
  local reason="$1" generation_dir="$PENDING_GENERATION_DIR" metadata version digest assets image_guidance
  PENDING_GENERATION=""
  PENDING_GENERATION_DIR=""
  PENDING_OLD_GENERATION=""
  metadata="$generation_dir/metadata"
  [[ -d "$generation_dir" && -f "$metadata" && ! -L "$metadata" ]] \
    || die "$reason; automatic rollback failed; pending recovery data is incomplete"
  version="$(previous_value OCI_AWS_PREVIOUS_VERSION "$metadata")" \
    || die "$reason; automatic rollback failed; pending recovery metadata is unreadable"
  digest="$(previous_value OCI_AWS_PREVIOUS_DIGEST "$metadata")" \
    || die "$reason; automatic rollback failed; pending recovery metadata is unreadable"
  assets="$(previous_value OCI_AWS_PREVIOUS_ASSETS "$metadata")" \
    || die "$reason; automatic rollback failed; pending recovery metadata is unreadable"
  [[ "$version" =~ ^sha-[0-9a-f]{7}$ ]] \
    || die "$reason; automatic rollback failed; pending recovery version is invalid"
  [[ "$digest" =~ ^ghcr\.io/nodewebzsz/oci-aws@sha256:[0-9a-f]{64}$ ]] \
    || die "$reason; automatic rollback failed; pending recovery digest is invalid"
  if [[ "$ROLLBACK_IMAGE_SOURCE" == "local" ]]; then
    image_guidance="prior image is already local; tag $digest as $IMAGE_REPOSITORY:$version"
  else
    image_guidance="manually pull $digest and tag it as $IMAGE_REPOSITORY:$version"
  fi
  if [[ "$assets" == "stored" ]]; then
    die "$reason; automatic rollback failed; database unchanged; $image_guidance; restore .env from $generation_dir/.env to $ENV_FILE; restore deployment assets from $generation_dir to $INSTALL_DIR (oci-aws.sh, compose.yml, SHA256SUMS); then start with $INSTALL_DIR/oci-aws.sh start"
  fi
  [[ "$assets" == "unchanged" ]] \
    || die "$reason; automatic rollback failed; pending recovery asset state is invalid"
  die "$reason; automatic rollback failed; database unchanged; $image_guidance; restore .env from $generation_dir/.env to $ENV_FILE; deployment assets are unchanged; then start with $INSTALL_DIR/oci-aws.sh start"
}

handle_update_signal() {
  local signal="$1"
  trap '' INT TERM HUP
  if [[ -n "$PENDING_GENERATION_DIR" ]]; then
    if rollback_pending_generation; then
      discard_pending_generation || true
      printf 'error: update interrupted by %s; rolled back to the previous deployment state\n' \
        "$signal" >&2
      exit 1
    fi
    die_pending_recovery_failed "update interrupted by $signal"
  fi
  die "update interrupted by $signal"
}

arm_update_signal_traps() {
  trap 'handle_update_signal INT' INT
  trap 'handle_update_signal TERM' TERM
  trap 'handle_update_signal HUP' HUP
}

clear_update_signal_traps() {
  trap - INT TERM HUP
}

rollback_image() {
  [[ -f "$PREVIOUS_FILE" ]] || {
    printf 'no rollback record is available\n' >&2
    return 1
  }
  local generation generation_dir
  validate_pull_timeout || die "invalid image pull timeout: $PULL_TIMEOUT"
  generation="$(previous_value OCI_AWS_PREVIOUS_GENERATION)" || return 1
  [[ "$generation" =~ ^generation-[0-9]+-[0-9]+$ ]] || {
    printf 'rollback record does not contain a valid generation\n' >&2
    return 1
  }
  generation_dir="$PREVIOUS_ASSET_DIR/$generation"
  rollback_generation "$generation_dir" yes || return 1
}

update_moving_image() {
  local target="$1" backup status target_env
  if timed_docker_pull "$IMAGE_REPOSITORY:$target"; then
    :
  else
    status=$?
    [[ "$status" -ne 124 ]] \
      || die "target image pull timed out after $PULL_TIMEOUT seconds; the current container was not stopped"
    die "target image pull failed; the current container was not stopped"
  fi
  trap 'discard_pending_generation || true' EXIT
  prepare_previous_generation unchanged \
    || die "could not create an atomic rollback generation; the current container was not stopped"
  arm_update_signal_traps
  if ! backup_database no no; then
    if rollback_pending_generation; then
      die "database backup failed; restored the previous image digest"
    fi
    die_pending_recovery_failed "database backup failed"
  fi
  backup="$BACKUP_PATH"
  target_env="$PENDING_GENERATION_DIR/.target-env"
  if ! render_env_value "$ENV_FILE" "$target_env" OCI_AWS_VERSION "$target"; then
    if rollback_pending_generation; then
      die "could not update .env; restored the previous image digest"
    fi
    die_pending_recovery_failed "could not update .env"
  fi
  if ! replace_deployment_assets "$ASSET_CURRENT" "$target_env"; then
    if rollback_pending_generation; then
      die "could not switch image selection; restored the previous image digest"
    fi
    die_pending_recovery_failed "could not switch image selection"
  fi
  rm -f "$target_env" || {
    if rollback_pending_generation; then
      die "could not finalize image selection; restored the previous image digest"
    fi
    die_pending_recovery_failed "could not finalize image selection"
  }
  if compose up --pull never -d app && wait_healthy; then
    if ! publish_pending_generation; then
      if rollback_pending_generation; then
        die "new image started but rollback generation publication failed; restored the previous image"
      fi
      die_pending_recovery_failed "new image started but rollback generation publication failed"
    fi
    clear_update_signal_traps
    printf 'updated_to=latest backup=%s deployment_assets=unchanged\n' "$backup"
    trap - EXIT
    return
  fi
  compose logs --tail=100 app >&2 || true
  if rollback_pending_generation; then
    die "new image failed startup or health checks; rolled back by digest without restoring the database"
  fi
  die_pending_recovery_failed "new image failed startup or health checks"
}

update_stable_release() {
  local target="$1" staged_root target_digest image_id backup status target_env
  RELEASE_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/oci-aws-release.XXXXXX")" \
    || die "could not create release staging directory"
  trap '[[ -z "${RELEASE_STAGING:-}" ]] || "$CLEANUP_BIN" -rf "$RELEASE_STAGING" || true; discard_pending_generation || true' EXIT
  download_stable_release "$target" "$RELEASE_STAGING"
  staged_root="$RELEASE_STAGING/oci-aws-$target"
  IFS= read -r target_digest < "$RELEASE_STAGING/manifest-digest" \
    || die "manifest digest staging is incomplete"
  [[ "$target_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "manifest digest staging is invalid"

  if timed_docker_pull "$IMAGE_REPOSITORY@$target_digest"; then
    :
  else
    status=$?
    [[ "$status" -ne 124 ]] \
      || die "target image pull timed out after $PULL_TIMEOUT seconds; the current container was not stopped"
    die "target image pull failed; the current container was not stopped"
  fi
  image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$IMAGE_REPOSITORY@$target_digest")" \
    || die "target image inspection failed; the current container was not stopped"
  "$DOCKER_BIN" tag "$image_id" "$IMAGE_REPOSITORY:$target" \
    || die "target image tagging failed; the current container was not stopped"
  prepare_previous_generation stored \
    || die "could not create an atomic rollback generation; the current container was not stopped"
  arm_update_signal_traps
  if ! backup_database no no; then
    if rollback_pending_generation; then
      die "database backup failed; restored deployment assets and image digest"
    fi
    die_pending_recovery_failed "database backup failed"
  fi
  backup="$BACKUP_PATH"

  target_env="$PENDING_GENERATION_DIR/.target-env"
  if ! render_env_value "$ENV_FILE" "$target_env" OCI_AWS_VERSION "$target"; then
    if rollback_pending_generation; then
      die "stable release environment update failed; restored deployment assets and image digest"
    fi
    die_pending_recovery_failed "stable release environment update failed"
  fi
  if ! install_staged_assets "$staged_root" "$target_env"; then
    if rollback_pending_generation; then
      die "stable release installation failed; restored deployment assets and image digest"
    fi
    die_pending_recovery_failed "stable release installation failed"
  fi
  if ! rm -f "$target_env"; then
    if rollback_pending_generation; then
      die "stable release finalization failed; restored deployment assets and image digest"
    fi
    die_pending_recovery_failed "stable release finalization failed"
  fi
  if compose up --pull never -d app && wait_healthy; then
    if ! publish_pending_generation; then
      if rollback_pending_generation; then
        die "new release started but rollback generation publication failed; restored deployment assets and image digest"
      fi
      die_pending_recovery_failed "new release started but rollback generation publication failed"
    fi
    clear_update_signal_traps
    printf 'updated_to=%s digest=%s backup=%s deployment_assets=updated\n' \
      "$target" "$target_digest" "$backup"
    if ! "$CLEANUP_BIN" -rf "$RELEASE_STAGING"; then
      printf 'warning: release staging cleanup failed; retained_path=%s; retrying on exit\n' \
        "$RELEASE_STAGING" >&2
      return
    fi
    RELEASE_STAGING=""
    trap - EXIT
    return
  fi
  compose logs --tail=100 app >&2 || true
  if rollback_pending_generation; then
    die "new release failed startup or health checks; restored deployment assets and image digest without restoring the database"
  fi
  die_pending_recovery_failed "new release failed startup or health checks"
}

update_image() {
  local target="$1"
  validate_pull_timeout || die "invalid image pull timeout: $PULL_TIMEOUT"
  if [[ "$target" == "latest" ]]; then
    update_moving_image "$target"
    return
  fi
  [[ "$target" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "invalid image version: $target"
  update_stable_release "$target"
}

install_assets() {
  local status
  verify_release_assets
  require_docker
  validate_pull_timeout || die "invalid image pull timeout: $PULL_TIMEOUT"
  prepare_state_directories
  create_env_once
  replace_deployment_assets "$SCRIPT_DIR" "$ENV_FILE" || return 1
  chmod 600 "$ENV_FILE"
  require_secret
  if timed_compose_pull_app; then
    :
  else
    status=$?
    [[ "$status" -ne 124 ]] \
      || die "initial image pull timed out after $PULL_TIMEOUT seconds"
    die "initial image pull failed"
  fi
  compose up --pull never -d app
  wait_healthy || {
    compose logs --tail=100 app >&2 || true
    die "health check failed"
  }
  printf 'install_dir=%s url=http://localhost:%s\n' "$INSTALL_DIR" "$(env_value PORT 18168)"
  print_running_version
}

print_usage() {
  cat <<'USAGE'
AWSLauncher public image deployment tool
usage: ./oci-aws.sh <install|start|stop|restart|status|logs|backup|update [version]|rollback|uninstall|url|version|help>
USAGE
}

command_name="${1:-help}"
case "$command_name" in
  install)
    install_assets
    ;;
  start)
    require_installed
    require_docker
    compose up --pull never -d app
    wait_healthy || die "health check failed"
    ;;
  stop)
    require_installed
    require_docker
    compose stop app
    ;;
  restart)
    require_installed
    require_docker
    compose restart app
    wait_healthy || die "health check failed"
    ;;
  status)
    require_installed
    require_docker
    compose ps
    ;;
  logs)
    require_installed
    require_docker
    compose logs -f app
    ;;
  backup)
    require_installed
    require_docker
    backup_database yes
    ;;
  update)
    require_installed
    require_docker
    target="${2:-}"
    [[ -n "$target" ]] || target="$(latest_stable_version)"
    update_image "$target"
    ;;
  rollback)
    require_installed
    require_docker
    rollback_image || die "image rollback failed; database unchanged"
    ;;
  uninstall)
    require_installed
    require_docker
    compose down --remove-orphans
    printf 'data retained at %s\n' "$DATA_DIR"
    ;;
  url)
    require_installed
    printf 'http://localhost:%s\n' "$(env_value PORT 18168)"
    ;;
  version)
    require_installed
    require_docker
    print_running_version
    ;;
  help|-h|--help)
    print_usage
    ;;
  *)
    print_usage >&2
    exit 1
    ;;
esac
