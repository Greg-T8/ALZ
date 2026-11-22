# Shared Proxmox CI/CD runners for Azure infrastructure

This folder holds **local Ubuntu VM bootstrap scripts** for the shared execution layer used by ALZ and, later, EPAC, AzOps, AVM, AMBA, and custom Azure IaC pipelines. The scripts do not provision Azure resources, create Proxmox VMs, or modify ALZ Terraform state.

| Tenant | CI platform | Suggested VM | Runner/agent | Selector |
|---|---|---|---|---|
| Lab | GitHub Actions | `ci-gh-01` | `gh-azure-01` | `[self-hosted, linux, x64, azure-iac]` |
| Sandbox | Azure DevOps | `ci-ado-01` | `ado-azure-01` | Pool `Azure-IaC` |
| Test | Local Terraform | Workstation | N/A | N/A |

## 1. Prepare dedicated Ubuntu hosts

- Provision **separate Ubuntu LTS VMs**, initially 2 vCPU, 8 GB RAM, 60 GB disk each. Adjust based on usage.
- Create a **dedicated non-root OS account** for each runner; give that account appropriate access to its own home directory only.
- Install a maintained toolchain: PowerShell 7, Git, Terraform (pinned), Azure CLI, jq and optional Bicep/Python. Follow vendor installation procedures and use version locks; this repository does not assume an unreviewed `curl | sudo bash` installation.
- Check tool presence with `bash runners/common/Test-RunnerPrerequisites.sh`.
- Allow outbound TCP 443 to your CI provider, Entra ID, Azure APIs and Terraform Blob backend. No inbound home router forwarding is needed.
- Restrict GitHub repository access and ADO pool/project authorization. These are **persistent hosts**, so authorize only trusted code and clean work directories between jobs as necessary.

## 2. GitHub runner (Lab)

In GitHub Settings > Actions > Runners, choose **New self-hosted runner** and select Linux x64. Download the runner archive using the current official link. Obtain the archive SHA-256 shown in the setup instructions, and download the temporary registration token.

As the dedicated runner user, set the ephemeral token without committing it or placing it in a shell-history command. Then run:

```bash
read -rs -p 'GitHub registration token: ' GITHUB_RUNNER_REGISTRATION_TOKEN
echo
export GITHUB_RUNNER_REGISTRATION_TOKEN
bash runners/github/Install-Runner.sh \
  --url https://github.com/OWNER/REPOSITORY \
  --archive /path/to/actions-runner-linux-x64.tar.gz \
  --sha256 'REPLACE_WITH_OFFICIAL_SHA256' \
  --name gh-azure-01 \
  --labels azure-iac
unset GITHUB_RUNNER_REGISTRATION_TOKEN
```

The script verifies the SHA-256, refuses a nonempty destination and registers the runner. Afterwards use its printed `sudo ./svc.sh install` and `sudo ./svc.sh start` commands, or pass `--install-service`. For organization-level registration, use the GitHub organization URL and ensure runner group/repository permissions are configured separately.

To select the runner in a workflow:

```yaml
jobs:
  validate:
    runs-on: [self-hosted, linux, x64, azure-iac]
```

Official guide: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners

## 3. Azure DevOps agent (Sandbox)

In Azure DevOps Organization settings > Agent pools, create or locate the **Azure-IaC** pool. Authorize the selected project/pipelines. Use the Linux agent download offered by Azure DevOps, and obtain a verified checksum through a trusted distribution channel (or securely compute and record one from the original download before copying the archive to the VM).

As the dedicated agent user:

```bash
read -rs -p 'Azure DevOps registration PAT: ' AZDO_AGENT_REGISTRATION_PAT
echo
export AZDO_AGENT_REGISTRATION_PAT
bash runners/azuredevops/Install-Agent.sh \
  --organization-url https://dev.azure.com/YOUR_ORGANIZATION \
  --pool Azure-IaC \
  --archive /path/to/azure-pipelines-agent-linux-x64.tar.gz \
  --sha256 'REPLACE_WITH_VERIFIED_SHA256' \
  --name ado-azure-01
unset AZDO_AGENT_REGISTRATION_PAT
```

The PAT requires Agent Pools (Read & manage) for registration; it is not the pipeline's Azure deployment credential. The agent subsequently uses its own listener/job credentials. Start the systemd service using the printed commands or `--install-service`.

```yaml
pool:
  name: Azure-IaC
```

Official guide: https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

## 4. Separate runner registration from Azure deployment authorization

- **GitHub:** ALZ Terraform workflows continue to use GitHub OIDC (`id-token: write`) and the existing plan/apply Entra identities.
- **Azure DevOps:** Terraform workflows continue to authenticate through federated Azure Resource Manager service connections.
- **Bootstrap:** `bootstrap/Deploy-BootstrapWithKeyVault.ps1` retrieves temporary bootstrap PATs from Azure Key Vault as needed and supports the Microsoft bootstrap-module override parameter. Do not store enrollment tokens, Azure credentials, Terraform state, saved plans, or bootstrap logs in this public repository.
- **Migration:** Validate runner authentication and state connectivity before making bootstrap Terraform changes; remove ACI/ACR only after reviewing a generated plan.

## 5. Status and next changes

The scripts here are an **initial registration scaffold**, not a fully automated Proxmox VM image. The following are still separate implementation tasks: Ubuntu provisioning/patching, runner download/version update strategy, ALZ platform bootstrap BYO-runner Terraform customization, state firewall hardening, smoke workflow tests, rollback and production-like acceptance tests.

The ALZ Google Docs progress tracker and implementation guide are the authoritative work plan. Do not run the migration against a live environment solely from this scaffold.
