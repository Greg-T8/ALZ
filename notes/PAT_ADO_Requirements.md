For this ALZ Azure DevOps bootstrap, create two separate PATs in the target Azure DevOps organization.

| PAT | Required scopes |
|---|---|
| `azure_devops_personal_access_token` | Agent Pools — **Read & manage**; Build — **Read & execute**; Code — **Full**; Environment — **Read & manage**; Graph — **Read & manage**; Pipeline Resources — **Use & manage**; Project and Team — **Read, write & manage**; Service Connections — **Read, query & manage**; Variable Groups — **Read, create & manage** |
| `azure_devops_agents_personal_access_token` | Agent Pools — **Read & manage** only |

The first PAT is for Terraform creating the project, repos, pipelines, environments, service connections, approvals, groups, and agent pool. Use a short expiration—ALZ’s current guidance says one day for bootstrap. The agent PAT is supplied only when `use_self_hosted_agents: true`; it registers the ACI agents and needs only the single Agent Pools scope. Microsoft notes that registration PATs are used during agent setup, not normal subsequent agent communication. [ALZ Azure DevOps prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/), [Microsoft agent-registration guidance](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/personal-access-token-agent-registration?view=azure-devops).
