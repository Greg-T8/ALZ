For the GitHub configuration, create fine-grained PATs with the organization as the resource owner and initially grant access to **all repositories**.

| PAT | Required permissions |
|---|---|
| `github_personal_access_token` | Repository: Actions, Administration, Contents, Environments, Secrets, Variables, Workflows — all **Read and write**. Organization: Members — **Read and write**; Self-hosted runners — **Read and write** only if using organization-level runner groups. |
| `github_runners_personal_access_token` | Repository: Administration — **Read and write**. Organization: Self-hosted runners — **Read and write** only if using organization-level runner groups. |

Use the bootstrap PAT for one day if practical. The runner PAT is required only when `use_self_hosted_runners: true`; it has to remain valid for agents to register, so establish a rotation process. After bootstrap, reduce its repository access to the repository running the self-hosted runners. The Accelerator requires a GitHub organization, not a personal account. [ALZ GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/).
