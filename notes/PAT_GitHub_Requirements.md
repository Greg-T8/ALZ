# GitHub Personal Access Token Requirements

This bootstrap uses GitHub fine-grained personal access tokens (PATs). Create
them under the GitHub user that will administer the ALZ GitHub organization.
The token can perform only actions that its owner is already allowed to perform.

## Create a fine-grained PAT in GitHub

1. Sign in to GitHub as the organization administrator.
2. Select your profile picture, then select **Settings**.
3. In the left navigation, select **Developer settings**.
4. Under **Personal access tokens**, select **Fine-grained tokens**.
5. Select **Generate new token**.
6. Enter a descriptive token name, such as `Azure Landing Zone` or
   `Azure Landing Zone Runners`.
7. Choose an expiration. Use one day for the bootstrap token when practical.
   Choose an expiry that supports the documented rotation process for the
   runner token.
8. Set **Resource owner** to the GitHub organization, not the personal account.
   If the organization requires approval, provide the justification and wait
   for approval before using the token.
9. Under **Repository access**, select **All repositories** for the initial
   bootstrap. After bootstrap, reduce the bootstrap token to the repository
   that runs the self-hosted runners.
10. Under **Permissions**, select the permissions in the applicable row below,
    then select **Generate token**.
11. Copy the token immediately. GitHub does not show its value again. Store it
    only in the approved secret store or process-scoped secret variable; never
    commit it to a repository, add it to a `.tfvars` file, or paste it into
    logs.

## Required permissions

For the GitHub configuration, initially grant access to **all repositories**.

| PAT | Required permissions |
|---|---|
| `github_personal_access_token` | Repository: Actions, Administration, Contents, Environments, Secrets, Variables, Workflows — all **Read and write**. Organization: Members — **Read and write**; Self-hosted runners — **Read and write** only if using organization-level runner groups. |
| `github_runners_personal_access_token` | Repository: Administration — **Read and write**. Organization: Self-hosted runners — **Read and write** only if using organization-level runner groups. |

Use the bootstrap PAT for one day if practical. The runner PAT is required only when `use_self_hosted_runners: true`; it has to remain valid for agents to register, so establish a rotation process. After bootstrap, reduce its repository access to the repository running the self-hosted runners. The Accelerator requires a GitHub organization, not a personal account. [ALZ GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/).

## Replace an expired token

Create a replacement rather than attempting to reactivate an expired PAT.
Update the secret value consumed by the bootstrap, then run a fresh Terraform
plan. Revoke the expired token once the replacement has been verified.

For GitHub's current token-creation guidance, see [Managing your personal
access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
