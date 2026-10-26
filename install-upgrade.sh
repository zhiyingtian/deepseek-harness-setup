#!/usr/bin/env bash
# Install or upgrade the official DSH npm package on Ubuntu and WSL2.
# Keep program releases, user data and caches under DSH_BASE; never install globally.
# Pair this entry point with dshctl.sh from the same repository checkout.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH_BASE="${DSH_BASE:-$HOME/deepseek-harness}"
DSH_VERSION="${DSH_VERSION:-latest}"
NODE_VERSION="${NODE_VERSION:-}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
NETWORK_TIMEOUT="${NETWORK_TIMEOUT:-300}"
START_SERVICE=1
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash install-upgrade.sh [--version <version|latest|next>] [--no-start] [--dry-run]

Run the same command to install or upgrade DSH on an online Ubuntu host.
No sudo, global npm install, shell-profile changes or system service changes.

Options:
  --version VALUE  Select an exact npm version or dist-tag (default: latest).
  --no-start       Install without starting Web; an existing service is stopped.
  --dry-run        Print the plan without network requests or filesystem changes.
  -h, --help       Show this help.

Environment:
  DSH_BASE         Installation root (default: ~/deepseek-harness)
  DSH_VERSION      npm version/tag (default: latest, not next)
  NODE_VERSION     Official Node 22 version, e.g. v22.23.4 (default: latest 22 LTS)
  NPM_REGISTRY     npm registry (default: https://registry.npmjs.org)
  NETWORK_TIMEOUT Network step timeout in seconds (default: 300)

DSH data, workspace, logs, downloads and backups stay under DSH_BASE.
dshmarket is installed by default. Other third-party plugins are preserved.
The Web port is owned by DSH; this installer does not pass --port.
On startup failure, restore the previous program and Web profile, not all user data.

Examples:
  bash install-upgrade.sh
  bash install-upgrade.sh --version 0.2.1-rc.2
  DSH_BASE=/absolute/path/to/dsh bash install-upgrade.sh
EOF
}

die() { echo "[ERROR] $*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || die "--version requires a value"; DSH_VERSION="$2"; shift 2 ;;
    --no-start) START_SERVICE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$DSH_BASE" = /* && "$DSH_BASE" != / ]] || die "DSH_BASE must be an absolute directory, not /"
[[ "$DSH_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]] || die "Invalid DSH version/tag"
[[ "$NETWORK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "NETWORK_TIMEOUT must be positive"
echo "[PLAN] Install root: $DSH_BASE"
echo "[PLAN] DSH: $DSH_VERSION; Node: ${NODE_VERSION:-latest Node 22 LTS}"
echo "[PLAN] Web: DSH default port (3080); start=$START_SERVICE; plugin=dshmarket"
if [ "$DRY_RUN" = 1 ]; then
  echo "[DRY-RUN] No downloads or filesystem changes."
  exit 0
fi

[ "$(uname -s)" = Linux ] || die "This installer requires Linux (Ubuntu)."
for command in curl tar xz sha256sum python3 flock timeout; do
  command -v "$command" >/dev/null || die "Missing $command; ask your administrator to install the Ubuntu prerequisite."
done
case "$(uname -m)" in
  x86_64) arch=linux-x64 ;;
  aarch64|arm64) arch=linux-arm64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$DSH_BASE" "$DSH_BASE/downloads" "$DSH_BASE/nodes" "$DSH_BASE/releases" "$DSH_BASE/backups" "$DSH_BASE/data" "$DSH_BASE/workspace" "$DSH_BASE/logs" "$DSH_BASE/cache" "$DSH_BASE/tmp"
exec 9>"$DSH_BASE/install.lock"
flock -n 9 || die "Another install/upgrade is running."
download() {
  curl --fail --location --retry 2 --connect-timeout 20 --max-time "$NETWORK_TIMEOUT" "$1" -o "$2"
}

# Download an isolated Node runtime and verify its archive before executing it.
if [ -z "$NODE_VERSION" ]; then
  download https://nodejs.org/dist/index.json "$DSH_BASE/downloads/node-index.json"
  NODE_VERSION="$(python3 - "$DSH_BASE/downloads/node-index.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    entries = json.load(source)
versions = [entry["version"] for entry in entries if entry["version"].startswith("v22.") and entry.get("lts")]
versions = [version for version in versions if tuple(map(int, version[1:].split("."))) >= (22, 19, 0)]
if not versions:
    raise SystemExit("No supported Node 22 LTS release found")
print(max(versions, key=lambda version: tuple(map(int, version[1:].split(".")))))
PY
)"
fi
[[ "$NODE_VERSION" =~ ^v22\.[0-9]+\.[0-9]+$ ]] || die "NODE_VERSION must be an official v22.x.y release"
node_name="node-$NODE_VERSION-$arch"
node_dir="$DSH_BASE/nodes/$node_name"
archive="$node_name.tar.xz"
download "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" "$DSH_BASE/downloads/SHASUMS256-$NODE_VERSION.txt"
checksum="$(awk -v name="$archive" '$2 == name {print $1}' "$DSH_BASE/downloads/SHASUMS256-$NODE_VERSION.txt")"
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || die "Node archive missing from official checksum manifest"
if [ ! -f "$DSH_BASE/downloads/$archive" ]; then
  download "https://nodejs.org/dist/$NODE_VERSION/$archive" "$DSH_BASE/downloads/$archive.part"
  mv "$DSH_BASE/downloads/$archive.part" "$DSH_BASE/downloads/$archive"
fi
printf '%s  %s\n' "$checksum" "$DSH_BASE/downloads/$archive" | sha256sum --check -
if [ ! -x "$node_dir/bin/node" ]; then
  tar -xJf "$DSH_BASE/downloads/$archive" -C "$DSH_BASE/nodes"
fi
export PATH="$node_dir/bin:$PATH"
node -e 'const version=process.versions.node.split(".").map(Number); if(version[0]!==22 || version[1]<19) process.exit(1)' || die "Node >=22.19 is required"
export npm_config_registry="$NPM_REGISTRY"
export npm_config_cache="$DSH_BASE/cache/npm"
export npm_config_devdir="$DSH_BASE/cache/node-gyp"
export XDG_CACHE_HOME="$DSH_BASE/cache"
export TMPDIR="$DSH_BASE/tmp"
export npm_config_fetch_timeout="$((NETWORK_TIMEOUT * 1000))"
export npm_config_fetch_retries=1
version="$(timeout "$NETWORK_TIMEOUT" npm view "@deepseek-ai/dsh@$DSH_VERSION" version --json | node -e 'let text="";process.stdin.on("data",chunk=>text+=chunk);process.stdin.on("end",()=>{const result=JSON.parse(text);if(typeof result!=="string")process.exit(1);console.log(result)})')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "Invalid resolved npm version: $version"
echo "[INFO] Resolved DSH $version, Node $NODE_VERSION"

# Prepare the new program before interrupting an existing service.
release="$DSH_BASE/releases/dsh-$version-$(date +%Y%m%d%H%M%S)-$$"
mkdir -p "$release/app"
ln -s "$node_dir" "$release/node"
printf '{"name":"dsh-ubuntu-online","private":true}\n' > "$release/app/package.json"
timeout "$NETWORK_TIMEOUT" npm install --prefix "$release/app" --save-exact --omit=dev --no-audit --no-fund "@deepseek-ai/dsh@$version" pnpm@11.7.0
cli="$release/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$cli" ] || die "Official DSH CLI missing after install"
"$release/node/bin/node" "$cli" --version

old_release=""
[ ! -L "$DSH_BASE/current" ] || old_release="$(readlink -f "$DSH_BASE/current")"
was_running=0
DSH_BASE="$DSH_BASE" bash "$SCRIPT_DIR/dshctl.sh" running && was_running=1
backup=""
# Stop the managed process before taking a consistent filesystem backup.
if [ -n "$old_release" ]; then
  backup="$DSH_BASE/backups/data-$(date +%Y%m%d%H%M%S)-$$.tar.gz"
  if [ "$was_running" = 1 ]; then
    DSH_BASE="$DSH_BASE" bash "$SCRIPT_DIR/dshctl.sh" stop
  fi
  if ! tar -czf "$backup" -C "$DSH_BASE" data; then
    [ "$was_running" != 1 ] || DSH_BASE="$DSH_BASE" bash "$SCRIPT_DIR/dshctl.sh" start || true
    die "Data backup failed; current release was not switched"
  fi
  echo "[INFO] Data backup: $backup"
fi

# Install plugins in a profile copy so failures leave the original profile intact.
profile_stage="$release/profile-data"
mkdir -p "$profile_stage/profiles"
if [ -d "$DSH_BASE/data/profiles/web" ]; then
  cp -a "$DSH_BASE/data/profiles/web" "$profile_stage/profiles/web"
fi
echo "[INFO] Installing/enabling dshmarket through the official profile command..."
if ! (
  export DSH_HOME="$profile_stage"
  export PATH="$release/app/node_modules/.bin:$release/node/bin:$PATH"
  cd "$release/app"
  timeout "$NETWORK_TIMEOUT" "$release/node/bin/node" "$cli" plugin --profile web add dshmarket
) || [ ! -f "$profile_stage/profiles/web/package.json" ]; then
  [ "$was_running" != 1 ] || DSH_BASE="$DSH_BASE" bash "$SCRIPT_DIR/dshctl.sh" start || true
  die "dshmarket installation failed; existing program and Web profile were not switched"
fi
mkdir -p "$DSH_BASE/data/profiles"
if [ -e "$DSH_BASE/data/profiles/web" ]; then
  mv "$DSH_BASE/data/profiles/web" "$release/previous-web-profile"
fi
mv "$profile_stage/profiles/web" "$DSH_BASE/data/profiles/web"
# Switch the program only after plugin installation; retain the old profile for rollback.
ln -s "$release" "$DSH_BASE/current.next"
mv -Tf "$DSH_BASE/current.next" "$DSH_BASE/current"
if [ "$START_SERVICE" = 1 ]; then
  if ! DSH_BASE="$DSH_BASE" bash "$SCRIPT_DIR/dshctl.sh" start; then
    echo "[ERROR] New release failed startup. See $DSH_BASE/logs/web.log" >&2
    mv "$DSH_BASE/data/profiles/web" "$release/failed-web-profile"
    if [ -e "$release/previous-web-profile" ]; then
      mv "$release/previous-web-profile" "$DSH_BASE/data/profiles/web"
    fi
    if [ -n "$old_release" ]; then
      ln -s "$old_release" "$DSH_BASE/current.rollback"
      mv -Tf "$DSH_BASE/current.rollback" "$DSH_BASE/current"
      echo "[INFO] Previous program and Web profile restored. Other data is not rolled back; backup: $backup"
      [ "$was_running" != 1 ] || DSH_BASE="$DSH_BASE" bash "$SCRIPT_DIR/dshctl.sh" start || true
    else
      rm "$DSH_BASE/current"
    fi
    exit 1
  fi
fi

echo "[DONE] DSH $version installed. Run this installer again to upgrade."
if [ "$START_SERVICE" = 1 ]; then
  web_url="$(grep -Eo 'dsh web: https?://[^[:space:]]+' "$DSH_BASE/logs/web.log" | tail -1 | sed 's/^dsh web: //' || true)"
  if [ -n "$web_url" ]; then
    echo "[DONE] Web link (keep token private): $web_url"
  fi
fi
echo "[INFO] Data: $DSH_BASE/data; workspace: $DSH_BASE/workspace"
echo "[INFO] Control: DSH_BASE=$(printf '%q' "$DSH_BASE") bash $(printf '%q' "$SCRIPT_DIR/dshctl.sh") status"
echo "[INFO] Configure model access in Web Settings; do not pass API secrets on the command line."