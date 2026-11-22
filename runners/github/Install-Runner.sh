#!/usr/bin/env bash
# Register one dedicated Linux GitHub Actions runner from a verified local archive.
# Run as the non-root Linux account that will own the runner service.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage:
  Install-Runner.sh --url https://github.com/OWNER/REPO --archive /path/actions-runner.tar.gz \
    --sha256 EXPECTED_SHA256 --name gh-azure-01 [--labels azure-iac] \
    [--directory "$HOME/actions-runner"] [--install-service]

Set GITHUB_RUNNER_REGISTRATION_TOKEN in the environment before running.
Obtain a short-lived registration token from GitHub Settings > Actions > Runners.
This script does not create an organization runner group or configure repository permissions.
USAGE
}

url="" archive="" sha256="" name="" labels="azure-iac"
directory="$HOME/actions-runner" install_service=false
while (($#)); do
  case "$1" in
    --url|--archive|--sha256|--name|--labels|--directory)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --url) url="$2";;
        --archive) archive="$2";;
        --sha256) sha256="$2";;
        --name) name="$2";;
        --labels) labels="$2";;
        --directory) directory="$2";;
      esac
      shift 2;;
    --install-service) install_service=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

[[ $EUID -ne 0 ]] || { echo "Run as a dedicated non-root runner account." >&2; exit 1; }
[[ "$url" =~ ^https://github\.com/[^/]+(/[^/]+)?/?$ ]] || { echo "Expected a GitHub repository or organization HTTPS URL." >&2; exit 2; }
[[ -n "$name" && -n "$labels" ]] || { echo "Name and labels are required." >&2; exit 2; }
[[ "$sha256" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Provide the official 64-character SHA-256 checksum." >&2; exit 2; }
[[ -f "$archive" ]] || { echo "Runner archive not found: $archive" >&2; exit 2; }
: "${GITHUB_RUNNER_REGISTRATION_TOKEN:?Set GITHUB_RUNNER_REGISTRATION_TOKEN before running}"

for command in tar sha256sum id; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done

printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status || {
  echo "Runner archive checksum mismatch." >&2
  exit 1
}

if [[ -d "$directory" && -n "$(ls -A "$directory")" ]]; then
  echo "Runner directory is not empty: $directory. Refusing to overwrite." >&2
  exit 1
fi

mkdir -p -- "$directory"
directory="$(cd "$directory" && pwd -P)"
tar --extract --gzip --file "$archive" --directory "$directory"
cd "$directory"
[[ -x ./config.sh && -f ./svc.sh ]] || { echo "Invalid GitHub runner archive." >&2; exit 1; }

./config.sh --unattended --url "$url" \
  --token "$GITHUB_RUNNER_REGISTRATION_TOKEN" \
  --name "$name" --labels "$labels" --work _work
unset GITHUB_RUNNER_REGISTRATION_TOKEN

if [[ "$install_service" == true ]]; then
  sudo ./svc.sh install "$(id -un)"
  sudo ./svc.sh start
  sudo ./svc.sh status
else
  echo "Runner registered. To run as a systemd service:"
  printf '  cd %q && sudo ./svc.sh install %q && sudo ./svc.sh start\n' "$directory" "$(id -un)"
fi
