The simplest distinction is:

| Folder | Role | What it affects |
|---|---|---|
| `output/bootstrap/` | Builds the deployment platform | GitHub/Azure DevOps repos, workflows, identities, permissions, Terraform state, and optional runners/networking |
| `output/starter/` | Contains the infrastructure that platform deploys | ALZ management groups, policies, roles, management resources, connectivity, and related configuration |

### How they work together

```text
inputs.yaml + scenario configuration
                 │
          Deploy-Accelerator
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
 bootstrap/v7.2.1    starter/v17.4.0
       │                   │
 creates GitHub/Azure      │ landing-zone Terraform
 deployment machinery     │ and ALZ library
       │                   │
       └──── publishes/configures ────┘
                         │
                 CI/CD runs Terraform
                         │
                         ▼
               Azure Landing Zone
```

The command that generated these folders is recorded in [Commands.md](C:/Users/gregt/LocalCode/Lab/ALZ/notes/Commands.md:1). The two packages are independently versioned: bootstrap `v7.3.0` and starter `v17.4.0`, as recorded in [.alz-version-data.json](C:/Users/gregt/LocalCode/Lab/ALZ/output/.alz-version-data.json:2).

### `output/bootstrap/`

This is the ALZ Accelerator’s deployment/control-plane code.

The downloaded package contains three alternatives:

- `alz/github`
- `alz/azuredevops`
- `alz/local`

They are listed in the bootstrap package’s [configuration manifest](C:/Users/gregt/LocalCode/Lab/ALZ/output/bootstrap/v7.3.0/.config/ALZ-Powershell.config.json:2). This scenario selected the GitHub implementation.

When its Terraform runs, it:

- Creates Azure storage for Terraform remote state.
- Creates managed identities, OIDC federated credentials, roles, and role assignments.
- Optionally creates networking and self-hosted GitHub runners.
- Creates the main and template GitHub repositories.
- Adds environments, variables, approvers, and branch protection.
- Copies the selected starter-module files into the main repository.
- Installs CI and CD workflows that run Terraform plan and apply.

You can see those responsibilities wired together in the bootstrap [main.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/bootstrap/v7.3.0/alz/github/main.tf:10). In particular, it reads the starter folder, processes its files, and passes them into the GitHub repository module. The repository module then commits those files to GitHub in [repository_module.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/bootstrap/v7.3.0/modules/github/repository_module.tf:12).

So “bootstrap” means: establish everything necessary to deploy and operate the landing zone reliably.

### `output/starter/`

This is the deployable ALZ workload—the Terraform root module that ultimately manages Azure.

The package includes several choices:

- `platform_landing_zone`: the real, complete ALZ implementation.
- `empty`: a starting shell for building your own implementation.
- `test`: a test module that explicitly does not deploy a landing zone.

These choices are documented in the starter [configuration manifest](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/.config/ALZ-Powershell.config.json:2). This scenario selected `platform_landing_zone`.

That selected module deploys things such as:

- Management-group hierarchy
- Azure Policy definitions and assignments
- Role definitions
- Log Analytics and management resources
- Platform resource groups
- Optional hub-and-spoke or Virtual WAN connectivity

The module’s own overview is in its [README](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/platform_landing_zone/README.md:1). The management-group deployment begins in [main.management.groups.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/platform_landing_zone/main.management.groups.tf:1), while the monitoring/management resources are in [main.management.resources.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/platform_landing_zone/main.management.resources.tf:1).

For this scenario, `Deploy-Accelerator` added:

- Shared values such as subscription IDs and the parent management group to `terraform.tfvars.json`.
- Your scenario configuration as `platform-landing-zone.auto.tfvars`.
- Your custom ALZ library under `lib/`.

### Active configuration layout

The repository maintains one active deployment. Its inputs and generated files are
at the repository root:

```text
config/
  active.platform-landing-zone.tfvars
  profiles/
  lib/
  bootstrap/
output/
```

`config/profiles/` retains reusable landing-zone configurations. Before deploying a
different scenario, copy its profile over `active.platform-landing-zone.tfvars` and
regenerate `output/`. `config/bootstrap/` contains Terraform-only GitHub and Azure
DevOps input templates; GitHub remains the active bootstrap configuration in
`bootstrap/inputs.yaml`.

### Practical rule

Treat `bootstrap/` and `starter/` as generated, versioned working artifacts:

- Change bootstrap-wide choices in [inputs.yaml](C:/Users/gregt/LocalCode/Lab/ALZ/bootstrap/inputs.yaml).
- Change active landing-zone behavior in `config/active.platform-landing-zone.tfvars`.
- Change policy/archetype definitions in `config/lib/`.
- Rerun `Deploy-Accelerator` to regenerate the output.

Direct edits inside `output/bootstrap/` or `output/starter/` may be overwritten on regeneration.

One important security issue: two GitHub PATs currently appear in plaintext in tracked generated configuration at [terraform.tfvars.json](C:/Users/gregt/LocalCode/Lab/ALZ/output/bootstrap/v7.3.0/alz/github/terraform.tfvars.json:132), and their source fields are in tracked [inputs.yaml](C:/Users/gregt/LocalCode/Lab/ALZ/bootstrap/inputs.yaml:38). Those tokens should be revoked and replaced immediately, then removed from the files and Git history.
