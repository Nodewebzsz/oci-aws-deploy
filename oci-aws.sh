#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_TOOL_VERSION="deploy-v1.0.0"
IMAGE_REPOSITORY="ghcr.io/nodewebzsz/oci-aws"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${OCI_AWS_INSTALL_DIR:-/opt/oci-aws}"
COMPOSE_FILE="$INSTALL_DIR/compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DATA_DIR="$INSTALL_DIR/data"
BACKUP_DIR="$INSTALL_DIR/backups"
SUMS_FILE="$INSTALL_DIR/SHA256SUMS"
PREVIOUS_FILE="$INSTALL_DIR/.previous-version"
DOCKER_BIN="${OCI_AWS_DOCKER_BIN:-docker}"
COPY_BIN="${OCI_AWS_COPY_BIN:-cp}"
HEALTH_TIMEOUT="${OCI_AWS_HEALTH_TIMEOUT:-90}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  die "sha256sum or shasum is required"
}

verify_release_assets() {
  local sums="$SCRIPT_DIR/SHA256SUMS" asset expected actual
  [[ -f "$sums" ]] || die "SHA256SUMS is missing; download the complete immutable release"
  for asset in oci-aws.sh compose.yml; do
    expected="$(awk -v name="$asset" '$2 == name { print $1; exit }' "$sums")"
    [[ -n "$expected" ]] || die "SHA256SUMS does not contain $asset"
    actual="$(hash_file "$SCRIPT_DIR/$asset")"
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
  local key="$1" value="$2" tmp="$ENV_FILE.tmp.$$"
  if ! awk -F= -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
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
  umask 077
  cat > "$ENV_FILE" <<EOF
OCI_AWS_VERSION=latest
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

record_previous_version() {
  local container revision short image_id digest selection
  container="$(current_container)"
  [[ -n "$container" ]] || die "cannot create a rollback point without a running container"
  revision="$("$DOCKER_BIN" inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$container")"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] \
    || die "current image does not contain a valid OCI revision"
  short="${revision:0:7}"
  image_id="$("$DOCKER_BIN" inspect --format '{{.Image}}' "$container")"
  digest="$("$DOCKER_BIN" image inspect --format '{{index .RepoDigests 0}}' "$image_id")"
  [[ "$digest" =~ ^ghcr\.io/nodewebzsz/oci-aws@sha256:[0-9a-f]{64}$ ]] \
    || die "current image does not contain a valid GHCR digest"
  selection="$(env_value OCI_AWS_VERSION latest)"
  umask 077
  cat > "$PREVIOUS_FILE" <<EOF
OCI_AWS_PREVIOUS_VERSION=sha-$short
OCI_AWS_PREVIOUS_DIGEST=$digest
OCI_AWS_PREVIOUS_SELECTION=$selection
EOF
  chmod 600 "$PREVIOUS_FILE"
}

previous_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$PREVIOUS_FILE"
}

backup_database() {
  local restart_after="${1:-yes}" database="$DATA_DIR/oci-aws.sqlite" backup
  [[ -f "$database" ]] || die "database not found: $database"
  compose stop app || die "could not stop the application; backup was not created"
  backup="$BACKUP_DIR/oci-aws.sqlite.$(date -u +%Y%m%dT%H%M%SZ).$$.bak"
  if ! "$COPY_BIN" "$database" "$backup" || [[ ! -s "$backup" ]]; then
    rm -f "$backup"
    compose up --pull never -d app && wait_healthy \
      || die "backup failed and the original image could not be restarted"
    die "database backup failed; the original image was restarted"
  fi
  if [[ "$restart_after" == "yes" ]]; then
    compose up --pull never -d app || die "backup completed but the original image did not start"
    wait_healthy || die "backup completed but the original image failed its health check"
  fi
  printf '%s\n' "$backup"
  printf 'store OCI_AWS_SECRET_KEY separately from the database backup\n' >&2
}

rollback_image() {
  [[ -f "$PREVIOUS_FILE" ]] || {
    printf 'no rollback record is available\n' >&2
    return 1
  }
  local version digest image_id
  version="$(previous_value OCI_AWS_PREVIOUS_VERSION)"
  digest="$(previous_value OCI_AWS_PREVIOUS_DIGEST)"
  [[ "$version" =~ ^sha-[0-9a-f]{7}$ ]] || {
    printf 'rollback record does not contain an immutable sha tag\n' >&2
    return 1
  }
  [[ "$digest" =~ ^ghcr\.io/nodewebzsz/oci-aws@sha256:[0-9a-f]{64}$ ]] || {
    printf 'rollback record does not contain a valid digest\n' >&2
    return 1
  }
  "$DOCKER_BIN" pull "$digest" || return 1
  image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$digest")" || return 1
  "$DOCKER_BIN" tag "$image_id" "$IMAGE_REPOSITORY:$version" || return 1
  set_env_value OCI_AWS_VERSION "$version" || return 1
  compose up --pull never -d app || return 1
  wait_healthy || return 1
  printf 'rolled_back_to=%s digest=%s database=unchanged\n' "$version" "$digest"
}

update_image() {
  local target="${1:-latest}" backup digest
  [[ "$target" =~ ^(latest|v[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+|sha-[0-9a-f]{7})$ ]] \
    || die "invalid image version: $target"
  "$DOCKER_BIN" pull "$IMAGE_REPOSITORY:$target" \
    || die "target image pull failed; the current container was not stopped"
  record_previous_version
  backup="$(backup_database no)"
  if ! set_env_value OCI_AWS_VERSION "$target"; then
    compose up --pull never -d app && wait_healthy || true
    die "could not update .env; attempted to restart the original image"
  fi
  if compose up --pull never -d app && wait_healthy; then
    printf 'updated_to=%s backup=%s\n' "$target" "$backup"
    return
  fi
  compose logs --tail=100 app >&2 || true
  if rollback_image; then
    die "new image failed startup or health checks; rolled back by digest without restoring the database"
  fi
  digest="$(previous_value OCI_AWS_PREVIOUS_DIGEST 2>/dev/null || true)"
  die "new image and automatic rollback failed; database unchanged; manually pull $digest"
}

install_assets() {
  verify_release_assets
  require_docker
  prepare_state_directories
  [[ "$SCRIPT_DIR/compose.yml" == "$COMPOSE_FILE" ]] \
    || install -m 0644 "$SCRIPT_DIR/compose.yml" "$COMPOSE_FILE"
  [[ "$SCRIPT_DIR/oci-aws.sh" == "$INSTALL_DIR/oci-aws.sh" ]] \
    || install -m 0755 "$SCRIPT_DIR/oci-aws.sh" "$INSTALL_DIR/oci-aws.sh"
  [[ "$SCRIPT_DIR/SHA256SUMS" == "$SUMS_FILE" ]] \
    || install -m 0644 "$SCRIPT_DIR/SHA256SUMS" "$SUMS_FILE"
  create_env_once
  chmod 600 "$ENV_FILE"
  require_secret
  compose pull app
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
    update_image "${2:-latest}"
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
