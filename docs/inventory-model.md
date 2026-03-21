# Inventory Model

## Purpose

This document explains how Azure dynamic inventory works in this repository and what happens when a playbook runs from a control node.

The repository does not store a manual list of VM hosts as the primary inventory source. Azure is the source of truth, and Ansible builds inventory dynamically at runtime.

## Inventory Source Files

Each inventory source file represents a specific control-plane slice.

Current concrete examples:

- `/Users/ekene/Documents/projects/dg/ansible-control/inventories/prod/azure_rm_automation_uksouth.yml`
- `/Users/ekene/Documents/projects/dg/ansible-control/inventories/nonprod/azure_rm_automation_uksouth.yml`

These files define:

- which inventory plugin to use
- how to authenticate to Azure
- which subscription to query
- which Azure hosts to include or exclude
- how discovered VMs are grouped inside Ansible
- which IP address Ansible should use for connection

They do not define static hosts manually.

## Current Azure Inventory Design

The `azure_rm_<subscription_alias>_<region>.yml` pattern is intentionally scoped to one control boundary:

- one subscription
- one region
- one environment directory (`prod` or `nonprod`)

Example fields:

- `plugin: azure.azcollection.azure_rm`
- `auth_source: msi`
- `subscription_id: 2376fd1e-fe1d-486e-8c70-b92ed2eb6308`
- `include_host_filters: location in ['uksouth']`

This means a specific control node:

- authenticates with its managed identity
- queries only the specified subscription
- keeps only VMs in `uksouth`

This does not mean every prod or nonprod controller should use the same file. Each controller should use the inventory file that matches its own:

- environment
- subscription alias
- region

Examples:

- `inventories/nonprod/azure_rm_automation_uksouth.yml`
- `inventories/prod/azure_rm_automation_uksouth.yml`
- `inventories/prod/azure_rm_shared_uksouth.yml`
- `inventories/prod/azure_rm_shared_westeurope.yml`

## Inventory Groups

The inventory plugin creates groups from Azure metadata and tags.

Examples from the current design:

- `windows`
- `linux`
- `managed`
- `subscription_automation`
- `env_prod`
- `env_nonprod`
- `region_uksouth`
- `workload_automation`
- `service_ansible`
- `sync_true`

These groups are created from:

- Azure `location`
- Azure `os_type`
- tags such as `environment`, `workload`, `service`, `subscription_alias`, and `sync_enabled`

## Required Tagging Expectations

For the inventory model to work reliably, managed VMs should carry consistent tags.

At minimum:

- `environment`
- `subscription_alias`
- `workload`
- `service`
- `sync_enabled`

For Windows hosts using `psrp` over `https` with Kerberos, also set:

- `connection_fqdn`

Example result:

- `subscription_alias=automation` -> `subscription_automation`
- `environment=prod` -> `env_prod`
- `sync_enabled=true` -> `sync_true` and `managed`

## Example Playbook Run

Example command:

```bash
ansible-playbook \
  -i inventories/prod/azure_rm_automation_uksouth.yml \
  playbooks/baseline/windows.yml \
  --limit 'windows:&managed:&env_prod:&region_uksouth:&subscription_automation'
```

This command means:

- use the production automation inventory for `uksouth`
- run the Windows baseline playbook
- target only hosts that match all of these groups:
  - `windows`
  - `managed`
  - `env_prod`
  - `region_uksouth`
  - `subscription_automation`

On a real controller, the default inventory path should come from that node's local bootstrap vars, not from a single hardcoded repo-wide default for all controllers.

## Explicit Runtime Flow

When the command above runs, the following happens.

1. Ansible starts on the control node.
2. Ansible reads `ansible.cfg` and the inventory file passed with `-i`.
3. Ansible sees `plugin: azure.azcollection.azure_rm` and loads the Azure dynamic inventory plugin.
4. The plugin authenticates to Azure using the control node's managed identity because `auth_source: msi` is set.
5. Azure evaluates RBAC for that managed identity.
6. If the identity has `Reader` at the required scope, Azure allows read-only discovery of resources in that scope.
7. The plugin queries Azure Resource Manager for VMs in subscription `2376fd1e-fe1d-486e-8c70-b92ed2eb6308`.
8. Because `include_vm_resource_groups` is `*`, it can consider all resource groups in that subscription.
9. The plugin applies `include_host_filters` and keeps only VMs where `location` is `uksouth`.
10. The plugin also applies its own default host filtering behavior so stopped or not-fully-provisioned hosts are not normally included.
11. For each remaining VM, the plugin reads metadata such as:
    - VM name
    - computer name
    - private IP addresses
    - Azure location
    - OS type
    - tags
12. The plugin sets `ansible_host` dynamically. For Windows hosts it uses the `connection_fqdn` tag so Kerberos and HTTPS certificate validation use the correct hostname. For Linux hosts it uses the private IP address.
13. The plugin builds inventory groups from tags and metadata.
14. A Windows VM in this scenario is placed into groups such as:
    - `windows`
    - `managed`
    - `env_prod`
    - `region_uksouth`
    - `subscription_automation`
15. After the inventory is built, Ansible loads `group_vars` and `host_vars` relevant to the discovered groups.
16. For Windows targets, Ansible loads Windows connection settings from `/Users/ekene/Documents/projects/dg/ansible-control/inventories/prod/group_vars/windows/10-connection.yml`.
17. Those variables tell Ansible to use:
    - `psrp`
    - `https`
    - port `5986`
    - Kerberos authentication
18. Ansible evaluates the `--limit` expression.
19. Only hosts that are members of all required groups remain in the execution set.
20. If the playbook uses Azure Key Vault lookups, those lookups execute on the control node and authenticate to Key Vault using the same managed identity.
21. Key Vault returns only the secrets the managed identity is allowed to read.
22. Ansible then opens a PSRP connection from the control node to each selected Windows VM on `5986`.
23. The control node validates the WinRM HTTPS certificate because certificate validation is enabled.
24. The control node authenticates to the Windows VM using Kerberos and the configured Ansible Windows credentials.
25. Kerberos and TLS validation both rely on the Windows endpoint being a resolvable FQDN that matches the WinRM certificate, which is why the inventory uses `connection_fqdn` for Windows.
26. If Kerberos succeeds, Ansible opens a PowerShell remoting session on the Windows VM.
27. The playbook tasks run inside that session.
28. Results are returned to the control node and reported per host.

## Separation of Permissions

Different permissions are used for different steps.

### Azure Reader

Used for:

- reading VM metadata from Azure Resource Manager
- discovering tags, IP addresses, names, and locations

Not used for:

- logging into the VM
- reading Key Vault secrets
- changing Azure resources

### Key Vault Secrets User

Used for:

- reading required secrets from Azure Key Vault during playbook execution

Not used for:

- building the Azure inventory
- logging into Azure Resource Manager
- connecting to the VM by itself

### Windows Credentials

Used for:

- authenticating from the control node to the Windows VM over PSRP

Not used for:

- querying Azure Resource Manager
- reading Azure Key Vault by themselves

## What the Control Node Does Not Do

The control node does not:

- keep a permanent manual host list for these VMs
- use Azure Reader to log into Windows or Linux machines
- use Key Vault Secrets User as a VM login permission
- automatically scan every subscription in the tenant unless explicitly configured to do so

## Multi-Subscription Scaling Pattern

For scale, copy the same inventory pattern and change the scope-defining fields.

Typical changes per new file:

- `subscription_id`
- `include_host_filters`
- file name

Typical changes per controller-local bootstrap vars file:

- `control_node_runtime_environment`
- `control_node_runtime_subscription_alias`
- `control_node_runtime_region`

Examples:

- `inventories/prod/azure_rm_shared_uksouth.yml`
- `inventories/prod/azure_rm_automation_westeurope.yml`
- `inventories/nonprod/azure_rm_shared_uksouth.yml`

This keeps the repository shared while execution scope stays narrow and explicit.
