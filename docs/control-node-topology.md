# Control Node Topology

## Purpose

This document defines the target operating model for Ansible control nodes in Azure.

The design goals are:

- strong security boundaries
- low operational overhead
- predictable scaling across subscriptions, regions, and environments
- clear separation of concerns between Terraform provisioning and Ansible configuration management

## Scope

This repository is used for post-provision configuration management of Azure-hosted virtual machines.

Terraform remains the source of truth for infrastructure creation, including:

- subscriptions and resource groups
- virtual networks and subnets
- virtual machines
- control node provisioning
- managed identities
- Key Vault instances and RBAC assignments
- baseline network rules

Ansible is the source of truth for:

- Windows and Linux baseline configuration
- hardening activities that are appropriate for ongoing configuration management
- agent installation and onboarding
- patch orchestration
- operational playbooks and drift correction

## Topology Decision

The standard design is:

- one control node per `region + subscription + environment`

Example:

- `uksouth + automation subscription + nonprod` -> one control node
- `uksouth + automation subscription + prod` -> one control node
- `westeurope + shared subscription + prod` -> one control node

This model is intentionally conservative. It reduces blast radius, keeps credentials and runtime identity narrow, and avoids a single controller becoming a cross-subscription or cross-environment dependency.

## Why Not One Controller Per Resource Group

Resource groups are not the right scaling unit for controller placement.

Using one controller per resource group would:

- create unnecessary operational sprawl
- increase cost and lifecycle overhead
- multiply identity and patching effort
- make inventory and execution harder to reason about

Resource groups can still be used as Azure RBAC scopes or inventory filters when needed, but they are not the default controller boundary.

## When a Fewer-Controller Model Is Acceptable

One control node per `subscription + environment` can be acceptable when:

- private connectivity exists across the required VNets and regions
- latency is not a concern
- the operational team is comfortable with a larger blast radius
- the same identity boundary is acceptable across those regions

This is simpler and cheaper, but less isolated.

The default standard remains one control node per `region + subscription + environment` unless there is a strong reason to consolidate.

## Azure Auth Model

Each control node authenticates to Azure using its own managed identity.

This identity is used for:

- Azure dynamic inventory queries
- Key Vault secret retrieval
- any future Azure API interactions needed by playbooks

The control node does not rely on:

- Azure CLI login for production execution
- stored client secrets
- certificate-based Azure service principal authentication

GitHub OIDC remains valid for CI/CD workflows such as Terraform runs, but it is not the runtime identity model for the control node itself.

## Managed Identity Design

Each control node should have a dedicated managed identity, preferably user-assigned when you want explicit lifecycle control and clearer reuse rules.

The identity should be granted least privilege only for the scope it is intended to manage.

Typical access pattern:

- read-only access to Azure resources required for dynamic inventory
- `Key Vault Secrets User` on the required Key Vaults

## RBAC Model

Azure RBAC scope is not region-based. Azure supports RBAC assignment at these scopes:

- management group
- subscription
- resource group
- resource

Because of this, region isolation is implemented by combining:

- separate control nodes
- scoped RBAC assignments at subscription or resource-group level
- private network boundaries
- inventory grouping and `--limit` usage

### Recommended RBAC Baseline

For inventory discovery, the control node identity should have one of:

- built-in `Reader` role at the smallest practical scope
- a custom read-only role if organizational policy requires tighter permissions than `Reader`

The minimum required scope should usually be:

- subscription scope when the controller manages that whole subscription slice
- resource-group scope when regional or workload boundaries map cleanly to resource groups

Avoid assigning broad permissions at tenant or management-group level for control-node runtime identities.

## Key Vault Design

Azure Key Vault is the standard secret source for the control node.

Store secrets such as:

- Linux SSH private keys if centrally managed
- test Windows local-admin or automation-account credentials
- Kerberos-related secrets if required by the final implementation
- agent onboarding secrets where applicable

Do not use Key Vault for ordinary configuration data such as:

- region names
- subscription aliases
- service names
- non-sensitive tagging metadata

The control node managed identity should be granted `Key Vault Secrets User` only on the vaults it needs.

## VM Access Model

### Windows

Target standard:

- `psrp` over `https` on port `5986`
- Kerberos authentication for AD-joined production servers

Transitional test standard:

- `psrp` over `https` on port `5986`
- self-signed or lab-issued certificate
- NTLM or Kerberos depending on test-domain readiness

### Linux

Target standard:

- SSH on port `22`
- dedicated non-human automation account
- key-based authentication only
- `sudo` for privilege escalation

## Network Model

Management traffic must stay private.

Control nodes should not depend on public inbound SSH or WinRM access to managed servers.

Recommended connectivity patterns:

- VNet peering
- hub-and-spoke routing with firewall control
- Virtual WAN only if the estate grows to justify it

Do not use Private Link for ordinary VM-to-VM management access. It is not the right pattern for SSH or PSRP between control nodes and virtual machines.

### NSG Expectations

Allow management ports only from approved control-plane sources:

- Linux SSH `22/tcp` only from the control node subnet, NIC, or ASG
- Windows PSRP `5986/tcp` only from the control node subnet, NIC, or ASG

Human administrative access should use a separate break-glass path such as:

- Azure Bastion
- Just-In-Time access

## Dynamic Inventory Model

The repository uses Azure dynamic inventory instead of static host lists.

This means Ansible discovers hosts from Azure at runtime based on:

- subscription context
- VM metadata
- tags
- Azure location

### Important Rule

`azure_rm.yml` does not define hosts manually.

It defines:

- how to authenticate to Azure
- which subscription to query
- which resource groups to include
- how discovered VMs are grouped in Ansible

### Subscription Scope

An inventory source file should normally represent one `subscription + environment` slice.

Examples:

- `inventories/nonprod/azure_rm_automation.yml`
- `inventories/prod/azure_rm_automation.yml`
- `inventories/prod/azure_rm_shared.yml`

Each inventory source should set:

- explicit `subscription_id`
- managed-identity-based authentication
- inventory grouping conventions shared across the repo

### Region Scope

Region scope is normally handled by inventory groups and playbook limits, not separate credentials.

Example:

```bash
ansible-playbook -i inventories/prod/azure_rm_automation.yml playbooks/baseline/common.yml --limit 'region_uksouth:&managed'
```

If operational isolation needs to be stronger, region-specific inventory files can also be created.

## Required Tagging Model

Dynamic inventory depends on consistent tags.

At minimum, managed VMs should include:

- `environment`
- `workload`
- `service`
- `application`
- `sync_enabled`
- `subscription_alias`

Recommended additional tags include:

- `owner`
- `cost_centre`
- `managed_by`
- `terraform_root`
- `region`

The tag `subscription_alias` is especially important because it creates readable Ansible groups such as:

- `subscription_automation`
- `subscription_shared`

The tag `sync_enabled=true` is the intended opt-in flag for Ansible-managed hosts.

## Repo Pull and Update Flow

The control node pulls this repository using the approved GitHub integration pattern already designed for the platform:

- GitHub-hosted workflow uses OIDC to authenticate to Azure
- Azure-side permissions are limited to the pull/update mechanism required for the control node
- control node receives repo updates through the approved pull path rather than broad interactive admin access

This keeps repository synchronization separate from VM-management credentials.

## Operational Guardrails

The following rules apply to all production-scale control nodes:

- no long-lived Azure client secrets stored on disk
- no public management exposure for target VMs
- no static host inventories as the primary source of truth
- no cross-environment credential reuse
- no targeting of hosts that are not explicitly opted in through tagging and inventory scope

## Initial Rollout

The first implementation target is:

- one control node in `uksouth`
- automation subscription
- non-production environment

This pilot should validate:

- managed identity auth to Azure
- Key Vault secret retrieval
- Azure dynamic inventory discovery
- Windows PSRP over HTTPS
- Linux SSH access with the automation account
- baseline playbook execution against a small mixed Windows/Linux test set

## Future Expansion

As the estate grows, expand by repeating the same pattern:

- add a new control node for a new `region + subscription + environment` boundary
- add the corresponding inventory source file
- assign least-privilege RBAC and Key Vault access
- validate network connectivity and NSG rules

The repository structure should remain shared. Scale is achieved through inventory scoping and control-plane boundaries, not by duplicating the repo.
