#!/usr/bin/env bash
# Install or upgrade the official DSH npm package on Ubuntu and WSL2.
# Keep program releases, user data and caches under DSH_BASE; never install globally.
# Node is picked from the selected DSH release's engines.node range, so upgrading
# DSH also upgrades the runtime it needs; pnpm stays installer-owned.
# Pair this entry point with dshctl.sh from the same repository checkout.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSH_BASE="${DSH_BASE:-$HOME/deepseek-harness}"
DSH_VERSION="${DSH_VERSION:-latest}"
NODE_VERSION="${NODE_VERSION:-}"
PNPM_VERSION="${PNPM_VERSION:-11.7.0}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
NETWORK_TIMEOUT="${NETWORK_TIMEOUT:-300}"
START_SERVICE=1
DRY_RUN=0
NODE_VERSION_OVERRIDE=0
[ -z "$NODE_VERSION" ] || NODE_VERSION_OVERRIDE=1

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
  NODE_VERSION     Pin an official Node release, e.g. v24.9.0
                   (default: newest stable Node satisfying the DSH release engines.node)
  PNPM_VERSION     Exact pnpm release used for plugin management (default: 11.7.0)
  NPM_REGISTRY     npm registry (default: https://registry.npmjs.org)
  NETWORK_TIMEOUT Network step timeout in seconds (default: 300)

DSH data, workspace, logs, downloads and backups stay under DSH_BASE.
Node is selected from the engines.node declared by the DSH version being installed:
the newest stable release satisfying that range. Releases that declare no
engines.node fall back to the Node 22 LTS line (>=22.19.0).
dshmarket is installed by default. Other third-party plugins are preserved.
The Web port is owned by DSH; this installer does not pass --port.
On startup failure, restore the previous program and Web profile, not all user data.

Examples:
  bash install-upgrade.sh
  bash install-upgrade.sh --version 0.2.1-rc.2
  NODE_VERSION=v26.13.0 bash install-upgrade.sh --version 0.2.2-rc.1
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
[[ "$PNPM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "PNPM_VERSION must be an exact pnpm release, e.g. 11.7.0"
[[ "$NETWORK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "NETWORK_TIMEOUT must be positive"
echo "[PLAN] Install root: $DSH_BASE"
echo "[PLAN] DSH: $DSH_VERSION; Node: ${NODE_VERSION:-auto from DSH engines.node (fallback Node 22 LTS)}; pnpm: $PNPM_VERSION"
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

# Semver helper shared by Node selection and NODE_VERSION validation: engines.node
# is a range, but nodejs.org only offers fixed releases, so one side must be mapped.
node_selector="$DSH_BASE/tmp/select-node.py"
cat > "$node_selector" <<'PY'
import json
import re
import sys

WILDCARDS = {"", "*", "x", "X"}
VERSION = re.compile(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-+][0-9A-Za-z.+-]+)?$")
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_version(text):
    match = VERSION.fullmatch(str(text).strip())
    if not match:
        fail(f"unsupported version {text!r}")
    parts = tuple(int(part) if part is not None else 0 for part in match.groups())
    precision = sum(part is not None for part in match.groups())
    return parts, precision


def parse_range_version(text):
    raw = str(text).strip().lstrip("v")
    raw = raw.split("-", 1)[0].split("+", 1)[0]
    numbers = []
    for segment in raw.split("."):
        if segment in ("x", "X", "*"):
            break
        if not segment.isdigit():
            fail(f"unsupported version {text!r}")
        numbers.append(int(segment))
    if not numbers:
        fail(f"unsupported version {text!r}")
    precision = len(numbers)
    return tuple(numbers + [0] * (3 - precision)), precision


def split_condition(condition):
    condition = condition.strip()
    if condition in WILDCARDS:
        return []
    match = re.fullmatch(r"(\^|~|>=|<=|>|<|=)?\s*(v?[0-9xX*][0-9A-Za-z.xX*+-]*)", condition)
    if not match:
        fail(f"unsupported engines.node condition {condition!r}")
    operator = match.group(1) or "="
    version, precision = parse_range_version(match.group(2))
    if operator == "=":
        if precision == 1:
            return [(">=", version), ("<", (version[0] + 1, 0, 0))]
        if precision == 2:
            return [(">=", version), ("<", (version[0], version[1] + 1, 0))]
        return [("=", version)]
    if operator == "^":
        if precision == 1 or version[0] > 0:
            upper = (version[0] + 1, 0, 0)
        elif version[1] > 0:
            upper = (0, version[1] + 1, 0)
        else:
            upper = (0, 0, version[2] + 1)
        return [(">=", version), ("<", upper)]
    if operator == "~":
        upper = (version[0] + 1, 0, 0) if precision == 1 else (version[0], version[1] + 1, 0)
        return [(">=", version), ("<", upper)]
    return [(operator, version)]


def parse_range(expression):
    expression = (expression or "").strip()
    if expression in WILDCARDS:
        return [[]]
    alternatives = []
    for chunk in expression.split("||"):
        chunk = chunk.strip()
        if not chunk:
            fail(f"unsupported engines.node range {expression!r}")
        hyphen = re.fullmatch(r"(\S+)\s+-\s+(\S+)", chunk)
        if hyphen:
            low, _ = parse_version(hyphen.group(1))
            high, high_precision = parse_version(hyphen.group(2))
            if high_precision == 3:
                alternatives.append([(">=", low), ("<=", high)])
            elif high_precision == 2:
                alternatives.append([(">=", low), ("<", (high[0], high[1] + 1, 0))])
            else:
                alternatives.append([(">=", low), ("<", (high[0] + 1, 0, 0))])
            continue
        chunk = re.sub(r"(?<=[><=~^])\s+", "", chunk)
        comparators = []
        for token in chunk.split():
            comparators.extend(split_condition(token))
        alternatives.append(comparators)
    return alternatives


def compare(version, operator, target):
    if operator == ">=":
        return version >= target
    if operator == ">":
        return version > target
    if operator == "<=":
        return version <= target
    if operator == "<":
        return version < target
    return version == target


def satisfies(version, expression):
    return any(
        all(compare(version, operator, target) for operator, target in alternative)
        for alternative in parse_range(expression)
    )


def select(index_path, expression):
    with open(index_path, encoding="utf-8") as source:
        entries = json.load(source)
    candidates = []
    for entry in entries:
        match = STABLE.fullmatch(str(entry.get("version", "")))
        if not match:
            continue
        version = tuple(map(int, match.groups()))
        if satisfies(version, expression):
            candidates.append(version)
    if not candidates:
        fail(f"no stable Node release satisfies engines.node {expression!r}")
    # Take the newest stable release the declared range allows: the installer
    # should run the newest Node the DSH release supports on this system, not
    # the oldest one it tolerates.
    version = max(candidates)
    print("v%d.%d.%d" % version)


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "select" and len(sys.argv) == 4:
        select(sys.argv[2], sys.argv[3])
    elif action == "check" and len(sys.argv) == 4:
        version, _ = parse_version(sys.argv[3])
        if not satisfies(version, sys.argv[2]):
            fail("Node v%d.%d.%d does not satisfy engines.node %r" % (version + (sys.argv[2],)))
    else:
        fail("usage: select-node.py select <index.json> <range> | select-node.py check <range> <version>")


if __name__ == "__main__":
    main()
PY

# Read the published metadata for the requested DSH version/tag before choosing a
# runtime: engines.node is the release's own contract for which Node it supports.
metadata="$DSH_BASE/downloads/dsh-packument.json"
download "${NPM_REGISTRY%/}/@deepseek-ai%2fdsh" "$metadata" || die "Could not fetch DSH metadata from $NPM_REGISTRY"
resolved="$(python3 - "$metadata" "$DSH_VERSION" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    packument = json.load(source)
spec = sys.argv[2]
version = (packument.get("dist-tags") or {}).get(spec) or spec
manifest = (packument.get("versions") or {}).get(version)
if not isinstance(manifest, dict):
    raise SystemExit(f"DSH {spec} is not published on the configured npm registry")
engines = manifest.get("engines") if isinstance(manifest.get("engines"), dict) else {}
print(manifest.get("version") or version)
print(engines.get("node") or "")
PY
)" || die "Could not resolve DSH $DSH_VERSION; check the version/tag and NPM_REGISTRY"
version="$(printf '%s\n' "$resolved" | sed -n '1p')"
node_range="$(printf '%s\n' "$resolved" | sed -n '2p')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "Invalid resolved DSH version: $version"
if [ -n "$node_range" ]; then
  node_select_range="$node_range"
  node_check_range="$node_range"
  echo "[INFO] DSH $version declares engines.node '$node_range'"
else
  # Releases before the engines field existed were supported on Node 22 LTS.
  node_select_range=">=22.19.0 <23.0.0"
  node_check_range=">=22.19.0"
  echo "[INFO] DSH $version declares no engines.node; using the Node 22 LTS baseline"
fi
if [ -z "$NODE_VERSION" ]; then
  download https://nodejs.org/dist/index.json "$DSH_BASE/downloads/node-index.json" || die "Could not download the Node release index"
  NODE_VERSION="$(python3 "$node_selector" select "$DSH_BASE/downloads/node-index.json" "$node_select_range")" || die "No Node release satisfies the DSH $version requirement"
fi
NODE_VERSION="${NODE_VERSION#v}"
[[ "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "NODE_VERSION must be an official Node release such as v24.9.0"
if [ "$NODE_VERSION_OVERRIDE" = 1 ]; then
  python3 "$node_selector" check "$node_check_range" "v$NODE_VERSION" || die "NODE_VERSION=v$NODE_VERSION is incompatible with DSH $version; omit NODE_VERSION to select a matching Node release"
fi
NODE_VERSION="v$NODE_VERSION"

# Download an isolated Node runtime and verify its archive before executing it.
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
[ -x "$node_dir/bin/npm" ] || die "Node archive is missing npm: $node_dir/bin/npm"
actual_node_version="$("$node_dir/bin/node" --version 2>/dev/null || true)"
[ "$actual_node_version" = "$NODE_VERSION" ] || die "Downloaded Node reports '${actual_node_version:-no version}', expected $NODE_VERSION"
export npm_config_registry="$NPM_REGISTRY"
export npm_config_cache="$DSH_BASE/cache/npm"
export npm_config_devdir="$DSH_BASE/cache/node-gyp"
export XDG_CACHE_HOME="$DSH_BASE/cache"
export TMPDIR="$DSH_BASE/tmp"
export npm_config_fetch_timeout="$((NETWORK_TIMEOUT * 1000))"
export npm_config_fetch_retries=1
echo "[INFO] Resolved DSH $version, Node $NODE_VERSION, pnpm $PNPM_VERSION"

# Prepare the new program before interrupting an existing service.
release="$DSH_BASE/releases/dsh-$version-$(date +%Y%m%d%H%M%S)-$$"
mkdir -p "$release/app"
ln -s "$node_dir" "$release/node"
printf '{"name":"dsh-ubuntu-online","private":true}\n' > "$release/app/package.json"
timeout "$NETWORK_TIMEOUT" npm install --prefix "$release/app" --save-exact --omit=dev --no-audit --no-fund "@deepseek-ai/dsh@$version" "pnpm@$PNPM_VERSION"
cli="$release/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$cli" ] || die "Official DSH CLI missing after install"
pnpm_cli="$release/app/node_modules/pnpm/bin/pnpm.cjs"
[ -f "$pnpm_cli" ] || die "pnpm $PNPM_VERSION is missing after install"
pnpm_version="$("$release/node/bin/node" "$pnpm_cli" --version 2>/dev/null || true)"
[ "$pnpm_version" = "$PNPM_VERSION" ] || die "pnpm reports '${pnpm_version:-no version}' on Node $NODE_VERSION; set PNPM_VERSION to a release compatible with that Node"
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
