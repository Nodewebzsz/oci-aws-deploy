#!/usr/bin/env bash
set -Eeuo pipefail

version="${1:-}"
digest="${2:-}"
revision="${3:-}"
output="${4:-}"

[[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "invalid version" >&2; exit 2; }
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid digest" >&2; exit 2; }
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid revision" >&2; exit 2; }
[[ -n "$output" ]] || { echo "output directory is required" >&2; exit 2; }
mkdir -p "$output"
[[ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || { echo "output directory must be empty" >&2; exit 1; }

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage_parent="$(mktemp -d)"
trap 'rm -rf "$stage_parent"' EXIT
root_name="oci-aws-$version"
stage="$stage_parent/$root_name"
mkdir -p "$stage"
chmod 0755 "$stage"

for name in .env.example .gitignore LICENSE README.md compose.yml oci-aws.sh; do
  cp "$source_root/$name" "$stage/$name"
done
chmod 0644 "$stage/.env.example" "$stage/.gitignore" "$stage/LICENSE" \
  "$stage/README.md" "$stage/compose.yml"
chmod 0755 "$stage/oci-aws.sh"
sed -i.bak -E "s/^OCI_AWS_VERSION=.*/OCI_AWS_VERSION=$version/" "$stage/.env.example"
rm -f "$stage/.env.example.bak"
sed -i.bak -E "s/^DEPLOY_TOOL_VERSION=.*/DEPLOY_TOOL_VERSION=\"$version\"/" "$stage/oci-aws.sh"
rm -f "$stage/oci-aws.sh.bak"
sed -i.bak "s/vX\\.Y\\.Z/$version/g" "$stage/README.md"
rm -f "$stage/README.md.bak"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

for name in .env.example .gitignore LICENSE README.md compose.yml oci-aws.sh; do
  printf '%s  %s\n' "$(hash_file "$stage/$name")" "$name"
done > "$stage/SHA256SUMS"
chmod 0644 "$stage/SHA256SUMS"

TZ=UTC find "$stage_parent" -exec touch -t 197001010000 {} +
bundle="oci-aws-$version-deploy.tar.gz"
if tar --version 2>&1 | grep -qi bsdtar; then
  COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root \
    -cf - -C "$stage_parent" "$root_name" | gzip -n > "$output/$bundle"
else
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=ustar \
    -cf - -C "$stage_parent" "$root_name" | gzip -n > "$output/$bundle"
fi

jq -n \
  --arg version "$version" --arg digest "$digest" --arg revision "$revision" --arg bundle "$bundle" \
  '{
    schemaVersion: 1,
    version: $version,
    image: {
      repository: "ghcr.io/nodewebzsz/oci-aws",
      digest: $digest,
      platforms: ["linux/amd64", "linux/arm64"]
    },
    signature: {
      certificateIdentity: ("https://github.com/Nodewebzsz/oci-aws/.github/workflows/release-image.yml@refs/tags/" + $version),
      oidcIssuer: "https://token.actions.githubusercontent.com"
    },
    source: {tag: $version, revision: $revision},
    bundle: $bundle
  }' > "$output/release-manifest.json"

for name in "$bundle" release-manifest.json; do
  printf '%s  %s\n' "$(hash_file "$output/$name")" "$name"
done > "$output/SHA256SUMS"
