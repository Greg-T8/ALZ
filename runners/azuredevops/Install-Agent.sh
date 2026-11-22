#!/usr/bin/env bash
# Register a dedicated Linux Azure Pipelines agent in an existing organization pool.
# Run as the non-root Linux account that will own the agent service.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage:
  Install-Agent.sh --organization-url https://dev.azure.com/ORG --pool Azure-IaC \
    --archive /path/agent.tar.gz --sha256 EXPECTED_SHA256 --name ado-azure-01 \
    [--directory "$HOME/ado-agent"] [--install-service]

Set AZDO_AGENT_REGISTRATION_PAT in the environment before running.
Use a short-lived PAT with Agent Pools (Read & manage) for agent registration.
The pool must already exist and be authorized for the desired projects/pipelines.
USAGE
}

organization_url="" pool="" archive="" sha256="" name=""
directory="$HOME/ado-agent" install_service=false
while (($#)); do
  case "$1" in
    --organization-url|--pool|--archive|--sha256|--name|--directory)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --organization-url) organization_url="$2";;
        --pool) pool="$2";;
        --archive) archive="$2";;
        --sha256) sha256="$2";;
        --name) name="$2";;
        --directory) directory="$2";;
      esac
      shift 2;;
    --install-service) install_service=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

[[ $EUID -ne 0 ]] || { echo "Run as a dedicated non-root agent account." >&2; exit 1; }
[[ "$organization_url" =~ ^https://dev\.azure\.com/[^/]+/?$ ]] || { echo "Expected https://dev.azure.com/ORG." >&2; exit 2; }
[[ -n "$pool" && -n "$name" ]] || { echo "Pool and agent name are required." >&2; exit 2; }
[[ "$sha256" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Provide a verified 64-character SHA-256 checksum." >&2; exit 2; }
[[ -f "$archive" ]] || { echo "Agent archive not found: $archive" >&2; exit 2; }
: "${AZDO_AGENT_REGISTRATION_PAT:?Set AZDO_AGENT_REGISTRATION_PAT before running}"

for command in tar sha256sum id; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status || {
  echo "Agent archive checksum mismatch." >&2
  exit 1
}

if [[ -d "$directory" && -n "$(ls -A "$directory")" ]]; then
  echo "Agent directory is not empty: $directory. Refusing to overwrite." >&2
  exit 1
fi
mkdir -p -- "$directory"
directory="$(cd "$directory" && pwd -P)"
tar --extract --gzip --file "$archive" --directory "$directory"
cd "$directory"
[[ -x ./config.sh && -f ./svc.sh ]] || { echo "Invalid Azure Pipelines agent archive." >&2; exit 1; }

./config.sh --unattended --url "$organization_url" \
  --auth pat --token "$AZDO_AGENT_REGISTRATION_PAT" \
  --pool "$pool" --agent "$name" --work _work --acceptTeeEula
unset AZDO_AGENT_REGISTRATION_PAT

if [[ "$install_service" == true ]]; then
  sudo ./svc.sh install "$(id -un)"
  sudo ./svc.sh start
  sudo ./svc.sh status
else
  echo "Agent registered. To run as a systemd service:"
  printf '  cd %q && sudo ./svc.sh install %q && sudo ./svc.sh start\n' "$directory" "$(id -un)"
fi
