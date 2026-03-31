# Hosting Decision Guide

This is the key question for your setup: should each Ubuntu machine pull from GitHub, or from an internal Git server?

## Recommendation for most small teams

Start with GitHub unless you already run stable internal infrastructure and want to own the operational burden of Git hosting.

Why:

- Faster time to value
- No internal Git server to patch, back up, and monitor
- Easy collaboration, issues, PRs, and history
- Good enough for workstation configuration in many environments

## When a public GitHub repo is a good first step

GitHub public is a good starting point if:

- The repo only contains generic workstation policy
- You keep all secrets and private host data out of Git
- You want the easiest possible bootstrap experience
- You are comfortable with package lists and hardening choices being visible

This removes per-device GitHub credential management entirely.

## When GitHub private repo is still the right answer

GitHub private is usually fine if:

- You have a small number of laptops/workstations
- Devices can reach GitHub directly
- Your config does not contain long-lived secrets in plain text
- You are okay using a read-only token, GitHub App flow, or deploy key strategy

## Annoyance: one SSH key per device

You are right that per-device SSH keys can get irritating.

Better options:

1. HTTPS with a read-only fine-grained personal access token stored at bootstrap time
2. Internal mirror with anonymous or network-restricted read access
3. A configuration management gateway or package that drops a shared read-only credential onto approved machines during provisioning

For `ansible-pull`, HTTPS plus a read-only credential is often simpler than SSH.

## Internal hosting benefits

Hosting your own repo internally can be worth it when:

- Machines should continue converging even without internet access
- You want repo access restricted to corporate network or VPN
- You want to avoid per-device GitHub auth management
- You need tighter control over audit, retention, and access boundaries
- You want a local mirror close to the fleet for speed and resilience

## Internal hosting costs

Internal hosting adds real maintenance:

- Git server setup and upgrades
- TLS, backups, monitoring, and disaster recovery
- User and service access management
- Extra operational dependency for every bootstrap and pull run

If you are just starting, that can slow the project down more than it helps.

## Practical starting architectures

### Option A: GitHub only

Best for: learning fast, tiny admin burden

- Host the repo in GitHub
- Start public if the contents are safe to expose
- Machines pull over HTTPS
- If you later go private, store a read-only token in a root-owned credential helper
- Use branch protection and CI

Tradeoff:

- External dependency
- Public repos expose your configuration shape
- Private repos require credential distribution

### Option B: GitHub as source of truth, internal mirror for clients

Best for: balancing ease and fleet simplicity

- Humans push to GitHub
- An internal Git service mirrors the repo
- Workstations pull from the internal mirror

This is often the sweet spot.

Benefits:

- Keep GitHub collaboration workflow
- Clients only need internal network access
- You can reduce device-by-device GitHub credential handling

### Option C: Fully internal Git

Best for: regulated or isolated environments

- Repo lives only internally
- Bootstrap and pull runs depend on your internal platform

Only choose this early if you already have the supporting systems and staff.

## My recommendation for you

Given your current goal, start with Option A as a public repo and make these choices:

- Use HTTPS, not SSH, for machine pulls
- Keep secrets out of the repo
- Keep the first playbook small and boring
- If you later need privacy, switch the repo to private and add a read-only machine credential

Then, if the fleet grows or internet dependence becomes a pain, introduce an internal mirror later without redesigning the Ansible structure.
