#!/usr/bin/env bash
# Build a runnable t3 directory like the release archive.
# Lives in its own local-build/ directory; it never edits upstream files.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${HOME}/tmp"
skip_build=0
with_resource_monitor=1
resource_monitor_binary=""

usage() {
  cat <<'EOF'
Usage: local-build/build-local-release.sh [options]

Builds web, the t3 single executable, and one runnable directory:
  <output-dir>/t3-<version>-<platform>-<arch>/
It contains the t3 command, client/, node_modules/, lib/ and install.sh. Run it
in place (serve) or move the whole directory; keep its contents together.

install.sh packages this directory only when it installs the background
service, so builds stay a plain directory. The command inside stays t3; the
folder name carries the version/platform/arch for side-by-side builds.

On non-Debian hosts a temporary dpkg-query shim supplies libatomic provenance so
the upstream archive script can run; the extracted license header is rewritten
for the local package manager. No upstream file is patched.

Options:
  --repo <dir>                  t3code checkout (default: this script's parent repo)
  --output-dir <dir>            Parent directory for the layout (default: $HOME/tmp)
  --resource-monitor-binary <file>
                                Stage this prebuilt t3-resource-monitor instead of cargo
  --skip-build                  Reuse existing web/server/executable builds
  --no-resource-monitor         Do not build or stage the Rust resource monitor
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="${2:?--repo needs a value}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?--output-dir needs a value}"
      shift 2
      ;;
    --version)
      echo "--version is no longer supported: the layout name comes from the checkout version." >&2
      exit 2
      ;;
    --resource-monitor-binary)
      resource_monitor_binary="${2:?--resource-monitor-binary needs a value}"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --no-resource-monitor)
      with_resource_monitor=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$repo_root/apps/server" ]]; then
  echo "Not a t3code checkout: $repo_root" >&2
  exit 1
fi
cd "$repo_root"

if [[ ! -x node_modules/.bin/vp ]]; then
  echo "node_modules/.bin/vp is missing in $repo_root. Install dependencies first." >&2
  exit 1
fi
export PATH="$repo_root/node_modules/.bin:$PATH"

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=mac ;;
  *)
    echo "Unsupported platform: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

target_key="${platform}-${arch}"
if [[ "$platform" == "mac" ]]; then
  target_key="darwin-${arch}"
fi

version="$(node -p "require('./apps/server/package.json').version")"

if [[ "$with_resource_monitor" -eq 0 && -n "$resource_monitor_binary" ]]; then
  echo "--no-resource-monitor conflicts with --resource-monitor-binary." >&2
  exit 2
fi

stem="t3-${version}-${target_key}"
layout="${output_dir}/${stem}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/t3-local-build.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT
mkdir -p "$work_dir/resource/$target_key" "$work_dir/bin" "$work_dir/out"

if [[ "$skip_build" -eq 0 ]]; then
  echo "[local-release] Building web client..."
  vp run --filter @t3tools/web build

  echo "[local-release] Building server bundle and bundling web into dist/client..."
  node apps/server/scripts/cli.ts build

  echo "[local-release] Building single executable for ${target_key}..."
  node apps/server/scripts/cli.ts build-exe --target "$target_key"
fi

if [[ -n "$resource_monitor_binary" ]]; then
  if [[ ! -x "$resource_monitor_binary" ]]; then
    echo "Not an executable resource monitor: $resource_monitor_binary" >&2
    exit 1
  fi
  echo "[local-release] Staging resource monitor from ${resource_monitor_binary}..."
  install -m 0755 "$resource_monitor_binary" \
    "$work_dir/resource/$target_key/t3-resource-monitor"
elif [[ "$with_resource_monitor" -eq 1 ]]; then
  if command -v cargo >/dev/null 2>&1; then
    echo "[local-release] Building resource monitor..."
    cargo build --locked --release --manifest-path native/resource-monitor/Cargo.toml
    cp "native/resource-monitor/target/release/t3-resource-monitor" \
      "$work_dir/resource/$target_key/t3-resource-monitor"
  else
    echo "[local-release] cargo not found; resource monitor will be unavailable." >&2
    echo "                 Pass --resource-monitor-binary <file> to stage a prebuilt one." >&2
  fi
fi

if ! command -v dpkg-query >/dev/null 2>&1; then
  cat >"$work_dir/bin/dpkg-query" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -S)
    path="${2:?}"
    pkg="$(pacman -Qoq "$path" 2>/dev/null || printf 'libatomic')"
    printf '%s: %s\n' "$pkg" "$path"
    ;;
  -W)
    pkg="${3:-libatomic}"
    pkg_version="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}' || true)"
    gcc_version="$(pacman -Q gcc 2>/dev/null | awk '{print $2}' || true)"
    printf '%s gcc %s\n' "${pkg_version:-0}" "${gcc_version:-0}"
    ;;
  *)
    exit 1
    ;;
esac
SHIM
  chmod +x "$work_dir/bin/dpkg-query"
  export PATH="$work_dir/bin:$PATH"
fi

echo "[local-release] Assembling ${layout}..."
node scripts/build-cli-archive.ts \
  --platform "$platform" \
  --arch "$arch" \
  --version "$version" \
  --resource-monitor-dir "$work_dir/resource" \
  --output-dir "$work_dir/out"

mkdir -p "$output_dir"
rm -rf "$layout"
tar -xzf "$work_dir/out/${stem}.tar.gz" -C "$output_dir"

if [[ "$platform" == "linux" ]] && command -v pacman >/dev/null 2>&1; then
  libatomic="$(readlink -f /usr/lib/libatomic.so.1 2>/dev/null || true)"
  pkg=""
  if [[ -n "$libatomic" ]]; then
    pkg="$(pacman -Qoq "$libatomic" 2>/dev/null || true)"
  fi
  if [[ -n "$pkg" ]]; then
    pkg_version="$(pacman -Q "$pkg" | awk '{print $2}')"
    {
      printf 'libatomic.so.1 is copied from the Arch Linux package %s %s.\n\n' \
        "$pkg" "$pkg_version"
      cat "$repo_root/scripts/licenses/libatomic.LICENSE"
    } >"$layout/lib/libatomic.so.1.LICENSE"
  fi
fi

install -m 0755 "$repo_root/local-build/install-local-release.sh" "$layout/install.sh"

echo
echo "[local-release] Ready: ${layout}"
echo "Run it here with:"
echo "  T3CODE_HOME=\"\${T3CODE_HOME:-/tmp/t3-local-home}\" ${layout}/t3 serve --host 127.0.0.1 --port 47917 --no-browser"
echo "Install it as a background service with:"
echo "  ${layout}/install.sh"
