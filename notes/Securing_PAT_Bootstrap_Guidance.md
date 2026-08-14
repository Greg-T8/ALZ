The best fit for this environment is to remove both PAT fields from `inputs.yaml` and inject them as session-scoped `TF_VAR_...` environment variables. ALZ 7.1.4 detects these variables and omits them from the generated `terraform.tfvars.json`.

### Recommended: prompt for the PATs at runtime

Remove these two entries entirely from [inputs.yaml](C:/Users/gregt/LocalCode/Lab/ALZ/bootstrap/inputs.yaml:37):

```yaml
# Supplied at runtime:
# TF_VAR_github_personal_access_token
# TF_VAR_github_runners_personal_access_token
```

Then run:

```powershell
$env:TF_VAR_github_personal_access_token = Read-Host `
  "GitHub bootstrap PAT" -MaskInput

$env:TF_VAR_github_runners_personal_access_token = Read-Host `
  "GitHub runner PAT" -MaskInput

try {
    Deploy-Accelerator `
      -Inputs .\bootstrap\inputs.yaml, .\config\active.platform-landing-zone.tfvars `
      -saf .\config\lib `
      -output .\output
}
finally {
    Remove-Item Env:\TF_VAR_github_personal_access_token -ErrorAction SilentlyContinue
    Remove-Item Env:\TF_VAR_github_runners_personal_access_token -ErrorAction SilentlyContinue
}
```

This keeps the values out of the command line, PowerShell history, YAML, and generated bootstrap tfvars. Terraform natively supports the `TF_VAR_name` convention. [Terraform environment-variable documentation](https://developer.hashicorp.com/terraform/cli/config/environment-variables#tf_var_name)

Avoid storing these as permanent user or machine environment variables; session-scoped values limit exposure.

### Retrieve them from a secret manager

For repeatable use, store them in Azure Key Vault or PowerShell SecretManagement and load them immediately before deployment.

Azure Key Vault example:

```powershell
$env:TF_VAR_github_personal_access_token = (
    az keyvault secret show `
      --vault-name "<vault-name>" `
      --name "alz-github-bootstrap-pat" `
      --query value `
      --output tsv
).Trim()

$env:TF_VAR_github_runners_personal_access_token = (
    az keyvault secret show `
      --vault-name "<vault-name>" `
      --name "alz-github-runner-pat" `
      --query value `
      --output tsv
).Trim()
```

Then run `Deploy-Accelerator` inside the same `try/finally` pattern. Azure CLI supports retrieving an individual Key Vault secret this way. [Azure Key Vault CLI reference](https://learn.microsoft.com/en-us/cli/azure/keyvault/secret?view=azure-cli-latest)

PowerShell SecretManagement follows the same pattern:

```powershell
$env:TF_VAR_github_personal_access_token =
    Get-Secret -Name "alz-github-bootstrap-pat" -AsPlainText
```

### Inject them from CI/CD secrets

If bootstrap is executed from a separate administrative GitHub repository or another CI system, map protected secrets into the process:

```yaml
env:
  TF_VAR_github_personal_access_token: ${{ secrets.ALZ_GITHUB_BOOTSTRAP_PAT }}
  TF_VAR_github_runners_personal_access_token: ${{ secrets.ALZ_GITHUB_RUNNER_PAT }}
```

Do not enable Terraform debug logging or shell command tracing while handling them.

### Eliminate the second PAT

Your second token exists because `use_self_hosted_runners` is currently `true`. Switching to:

```yaml
use_self_hosted_runners: false
```

eliminates the long-lived runner PAT requirement, but moves execution to GitHub-hosted runners. That is an architectural choice, not merely secret cleanup.

For self-hosted runners, Microsoft recommends separate fine-grained tokens: a short-lived bootstrap token and a narrowly scoped runner token. After bootstrap, restrict the runner token to the created repository. [ALZ GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/)

### Important state-file limitation

Environment variables solve configuration-file exposure, but not every Terraform-state exposure:

- The general bootstrap PAT is provider authentication and is not currently in your state.
- The runner PAT is passed into the Azure Container Instance as a secure environment variable and is present in your local Terraform state.

I verified both facts without printing either value. Terraform’s `sensitive = true` only redacts output; sensitive values can still be stored in state. [Terraform sensitive-data guidance](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)

Therefore:

- Keep `*.tfstate` and `*.tfstate.*` ignored.
- Restrict access to the bootstrap state directory.
- Use disk encryption.
- Treat state backups as secrets.
- Revoke old runner tokens when rotating them.

### Existing Git cleanup

Both PATs are already present in local Git history in two files:

- [bootstrap/inputs.yaml](C:/Users/gregt/LocalCode/Lab/ALZ/bootstrap/inputs.yaml:37)
- [terraform.tfvars.json](C:/Users/gregt/LocalCode/Lab/ALZ/output/bootstrap/v7.3.0/alz/github/terraform.tfvars.json)

This checkout has no configured Git remote, which reduces exposure, but you should still revoke both existing tokens. Also stop tracking generated bootstrap tfvars and add a targeted ignore rule such as:

```gitignore
output/bootstrap/**/alz/github/terraform.tfvars.json
```

Removing secrets from the latest commit does not remove them from history. After revocation, you can either leave the now-invalid values in local history or rewrite history with `git filter-repo` before adding a remote.
