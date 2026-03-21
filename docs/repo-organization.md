# Repo Organization

## Principle

Keep playbooks thin and keep reusable logic in roles.

The directory structure should scale by separating:

- execution entrypoints
- reusable configuration logic
- inventory-driven data
- controller-specific automation

## Playbooks

Playbooks should answer the question: "what are we trying to do?"

Current playbook categories:

- `playbooks/bootstrap/`
- `playbooks/baseline/`
- `playbooks/platform/`
- `playbooks/operations/`

Recommended meaning:

- `bootstrap/`: first-run or control-plane setup tasks such as controller bootstrap
- `baseline/`: desired-state configuration for Windows and Linux baselines
- `platform/`: shared platform integrations such as monitoring, backup, or security onboarding
- `operations/`: operator-invoked maintenance such as patching or controlled reboots

### How to Add New Playbooks

Create a playbook when you need a clear execution entrypoint.

Examples:

- `playbooks/platform/defender-onboarding.yml`
- `playbooks/operations/patch-windows.yml`
- `playbooks/bootstrap/control-node.yml`

Playbooks should mostly do three things:

- select hosts
- set high-level run context
- call roles

Avoid putting large task blocks directly in playbooks unless the logic is truly one-off.

## Roles

Roles should answer the question: "how is this capability implemented?"

Current role categories:

- `roles/linux_baseline`
- `roles/windows_baseline`
- `roles/azure_monitor_agent`
- `roles/defender_onboarding`
- `roles/control_node_runtime`

Recommended rule:

- one role per capability or tightly related capability set

Examples:

- `windows_baseline`: Windows hardening and common baseline controls
- `linux_baseline`: Linux hardening and common baseline controls
- `azure_monitor_agent`: monitoring-agent installation and config
- `control_node_runtime`: control-node-local runtime files, wrappers, repo sync scripts, systemd services, and timers

### Control Node vs Managed Node Logic

Keep controller-local automation separate from managed-node automation.

That means:

- control-node tasks belong in roles such as `control_node_runtime`
- Windows/Linux target-node tasks belong in platform or baseline roles

Do not mix controller systemd management into general Windows or Linux baseline roles.

Cloud-init should only do first-boot bootstrap. Persistent controller behavior belongs in the controller role, not in the cloud-init template.

## Inventory Data

Inventory should answer the question: "which hosts exist and what data shapes their behavior?"

Keep data in:

- `inventories/<env>/group_vars/all`
- `inventories/<env>/group_vars/windows`
- `inventories/<env>/group_vars/linux`
- `inventories/<env>/group_vars/subscription_*`
- `inventories/<env>/group_vars/region_*`

Use `group_vars` for data and roles for behavior.

## Naming Guidance

When adding new automation, use names that reflect purpose instead of technology.

Prefer:

- `azure_monitor_agent`
- `control_node_runtime`
- `windows_baseline`

Avoid vague names like:

- `misc`
- `shared`
- `custom`
- `tasks2`

## Growth Pattern

As the repo grows:

- add a new playbook when you need a new operator entrypoint
- add a new role when you introduce a reusable capability
- add new `group_vars` only when a scope actually needs different data

Do not create empty roles or playbooks for hypothetical future use. Create structure where it clarifies the design, but keep behavior concentrated in reusable roles.
