#!/usr/bin/env bash
# Install the t3 layout this script sits in as the background service.
# Packaging happens here, at install time, so builds stay a plain directory.
set -euo pipefail

layout=""
base_dir="${T3CODE_HOME:-${HOME}/.t3}"
port=8788
lan=1
reinstall=0
pack_only=""
keep_bundle=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Turns this t3 layout into the background service. The layout must stay together
(t3, client/, node_modules/, lib/); place this script inside it and run it there.

The release archive that `t3 up` requires is created now, in a temporary
directory, and removed when the install finishes.

Options:
  --dir <dir>            Layout to install (default: this script's directory)
  --base-dir <dir>       T3 data directory (default: $T3CODE_HOME or $HOME/.t3)
  --port <port>          Temporary localhost HTTP port (default: 8788)
  --no-lan               Do not expose the server on the LAN/tailnet
  --reinstall            Stop the old service and move the same-version runtime
                         aside before installing; needed when rebuilding the
                         same version
  --pack-only <dir>      Only write t3-<version>-<platform>-<arch>.tar.gz and
                         SHA256SUMS to <dir>; do not install
  --keep-bundle <dir>    Keep the generated archive and checksums in <dir>
  -h, --help             Show this help
EOF
}

fail() {
  printf 'install: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      layout="${2:?--dir needs a value}"
      shift 2
      ;;
    --base-dir)
      base_dir="${2:?--base-dir needs a value}"
      shift 2
      ;;
    --port)
      port="${2:?--port needs a value}"
      shift 2
      ;;
    --no-lan)
      lan=0
      shift
      ;;
    --reinstall)
      reinstall=1
      shift
      ;;
    --pack-only)
      pack_only="${2:?--pack-only needs a value}"
      shift 2
      ;;
    --keep-bundle)
      keep_bundle="${2:?--keep-bundle needs a value}"
      shift 2
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

if [[ -z "${layout}" ]]; then
  layout="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
layout="$(cd "${layout}" && pwd)" || fail "layout directory not found: ${layout}"
[[ -x "${layout}/t3" ]] || fail "no executable t3 in ${layout}"
[[ -f "${layout}/client/index.html" ]] ||
  fail "client/index.html is missing in ${layout}; keep the whole layout together"
[[ -d "${layout}/node_modules" ]] ||
  fail "node_modules is missing in ${layout}; keep the whole layout together"

version_output="$("${layout}/t3" --version)"
version="${version_output##* }"
version="${version#v}"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "could not read a version from: ${version_output}"

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=darwin ;;
  *) fail "unsupported platform: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

stem="t3-${version}-${platform}-${arch}"
layout_name="$(basename "${layout}")"
layout_parent="$(dirname "${layout}")"

write_checksums() {
  local target="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "${target}" && sha256sum "${stem}.tar.gz" >SHA256SUMS )
  elif command -v shasum >/dev/null 2>&1; then
    ( cd "${target}" && shasum -a 256 "${stem}.tar.gz" >SHA256SUMS )
  else
    fail "sha256sum or shasum is required"
  fi
}

make_bundle() {
  local target="$1"
  mkdir -p "${target}"
  rm -f "${target}/${stem}.tar.gz" "${target}/SHA256SUMS"
  tar -czf "${target}/${stem}.tar.gz" \
    -C "${layout_parent}" --exclude=install.sh "${layout_name}"
  write_checksums "${target}"
}

if [[ -n "${pack_only}" ]]; then
  make_bundle "${pack_only}"
  echo "install: wrote ${pack_only}/${stem}.tar.gz"
  echo "install: wrote ${pack_only}/SHA256SUMS"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required for the temporary local release source"
fi

bundle_dir=""
cleanup_bundle() {
  if [[ -n "${bundle_dir}" && -z "${keep_bundle}" ]]; then
    rm -rf "${bundle_dir}"
  fi
}

if [[ -n "${keep_bundle}" ]]; then
  bundle_dir="${keep_bundle}"
else
  bundle_dir="$(mktemp -d "${TMPDIR:-/tmp}/t3-release.XXXXXX")"
fi
make_bundle "${bundle_dir}"
echo "install: packaged ${stem} from ${layout}"

server_log="$(mktemp "${TMPDIR:-/tmp}/t3-release-http.XXXXXX.log")"
python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${bundle_dir}" \
  >"${server_log}" 2>&1 &
http_pid=$!
cleanup() {
  kill "${http_pid}" 2>/dev/null || true
  rm -f "${server_log}"
  cleanup_bundle
}
trap cleanup EXIT
sleep 0.5
if ! kill -0 "${http_pid}" 2>/dev/null; then
  cat "${server_log}" >&2
  fail "could not listen on 127.0.0.1:${port}; pass --port with a free port"
fi
if command -v curl >/dev/null 2>&1; then
  ready=0
  for _ in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${port}/SHA256SUMS" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.25
  done
  [[ "${ready}" -eq 1 ]] || fail "temporary release source did not become ready"
else
  sleep 1
fi

if [[ "${reinstall}" -eq 1 ]]; then
  echo "install: stopping the existing service..."
  T3CODE_HOME="${base_dir}" "${layout}/t3" service uninstall || true
  if [[ -d "${base_dir}/runtime/versions/${version}" ]]; then
    backup_root="${layout_parent}/t3-runtime-backups"
    mkdir -p "${backup_root}"
    mv "${base_dir}/runtime/versions/${version}" \
      "${backup_root}/${version}-$(date +%Y%m%d-%H%M%S)"
    echo "install: moved the previous ${version} runtime to ${backup_root}"
  fi
fi

up_args=(--yes)
if [[ "${lan}" -eq 1 ]]; then
  up_args=(--lan "${up_args[@]}")
else
  up_args=(--no-lan "${up_args[@]}")
fi

echo "install: installing the background service from this layout..."
T3CODE_HOME="${base_dir}" T3CODE_RELEASE_BASE_URL="http://127.0.0.1:${port}" \
  "${layout}/t3" up "${up_args[@]}"

echo
T3CODE_HOME="${base_dir}" "${layout}/t3" service status || true
echo
echo "install: pair a device with:"
echo "  T3CODE_HOME=\"${base_dir}\" ${layout}/t3 pair"
