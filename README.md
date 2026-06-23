# production-app-infra

A small Go API, deployed to AWS with Terraform, configured with Ansible, containerized with Docker, and shipped continuously via a GitHub Actions pipeline that deploys through AWS Systems Manager — with no SSH port ever exposed to the internet.

This repo is both a working deployment and a documented case study in infrastructure decision-making: what was tried, what broke, and why each fix was chosen over the easier alternative.

---

## Architecture

```
                         ┌─────────────────────────────┐
                         │         GitHub Actions       │
                         │  (push to main triggers run) │
                         └───────────────┬───────────────┘
                                         │ OIDC (short-lived token,
                                         │ no stored AWS keys)
                                         ▼
                         ┌─────────────────────────────┐
                         │   AWS IAM Role (assumed via   │
                         │   GitHub OIDC provider)       │
                         └───────────────┬───────────────┘
                                         │ ssm:SendCommand
                                         ▼
┌────────────────────────────────────────────────────────────────────┐
│                         AWS VPC (10.0.0.0/16)                       │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │                  Public Subnet (10.0.1.0/24)                │    │
│  │                                                              │    │
│  │   EC2 (t3.micro, Ubuntu 24.04)                               │    │
│  │   ┌────────────────────────────────────────────────────┐    │    │
│  │   │  Docker Compose                                     │    │    │
│  │   │                                                      │    │    │
│  │   │   ┌─────────┐    ┌──────────────┐    ┌────────────┐ │    │    │
│  │   │   │  nginx  │───▶│  Go backend  │───▶│  Postgres  │ │    │    │
│  │   │   │ :80     │    │  :8080       │    │  :5432     │ │    │    │
│  │   │   └─────────┘    └──────────────┘    └────────────┘ │    │    │
│  │   └────────────────────────────────────────────────────┘    │    │
│  │                                                              │    │
│  │   SSM Agent (pre-installed) — receives deploy commands       │    │
│  │   without any inbound connection required                    │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  Security Group: :80 open to 0.0.0.0/0 · :22 open to admin IP only │
└────────────────────────────────────────────────────────────────────┘
```

**Request flow:** Internet → Security Group (`:80`) → nginx → Go backend (`:8080`, internal only) → Postgres (`:5432`, internal only)

**Deploy flow:** `git push` → GitHub Actions assumes an AWS IAM role via OIDC → sends a shell command through AWS SSM → server runs `git pull` + rebuilds containers. No SSH connection is made by CI at any point.

---

## Tech Stack

| Layer | Tool | Why |
|---|---|---|
| Infrastructure provisioning | **Terraform** | Declarative, version-controlled AWS resources (VPC, EC2, IAM, security groups) |
| Configuration management | **Ansible** | Idempotent server setup — OS hardening, Docker install, firewall rules |
| Application | **Go** (`net/http`) | Minimal dependencies, fast cold start, single static binary |
| Reverse proxy | **nginx** | Public entry point; only service exposed on a host port |
| Database | **PostgreSQL 16** | Internal-only, never exposed to the host network |
| Containerization | **Docker Compose** | Reproducible multi-service runtime |
| CI/CD | **GitHub Actions** | Push-to-deploy automation |
| Deploy transport | **AWS SSM + OIDC** | Deploys without exposing inbound SSH or storing long-lived AWS credentials |

---

## Project Structure

```
production-app-infra/
├── Dockerfile                  # Multi-stage build for the Go binary
├── docker-compose.yml          # nginx + backend + postgres
├── nginx.conf                  # Reverse proxy config
├── go.mod
├── main.go                     # Go API entrypoint
├── infra/
│   ├── main.tf                 # VPC, subnets, EC2, security groups, IAM, OIDC provider
│   ├── variables.tf
│   ├── outputs.tf               # Public IPs, instance IDs, IAM role ARN
│   └── ansible/
│       ├── ansible.cfg
│       ├── hosts.ini            # Inventory (EC2 target)
│       └── playbook.yml         # OS prep, Docker install, repo clone, container boot
└── .github/
    └── workflows/
        └── deploy.yml            # OIDC auth → SSM send-command → redeploy
```

---

## Prerequisites

- AWS account with CLI configured (`aws configure`)
- Terraform `>= 1.0.0`
- Ansible (`brew install ansible` on macOS)
- An SSH key pair for initial provisioning (`aws_key_pair` in Terraform)
- A GitHub repository with Actions enabled

---

## Setup

### 1. Provision infrastructure

```bash
cd infra
terraform init
terraform plan
terraform apply
```

This creates the VPC, subnet, security group, EC2 instance, IAM role for SSM, and the IAM OIDC trust relationship GitHub Actions will assume.

Grab the outputs you'll need:
```bash
terraform output
```

### 2. Configure the server

Update `infra/ansible/hosts.ini` with the EC2 instance's public IP, then:

```bash
cd infra/ansible
ansible-playbook playbook.yml
```

This installs Docker, configures the firewall (UFW), clones this repository onto the instance, and boots the containers.

### 3. Wire up CI/CD

In the GitHub repo settings, no secrets are required for deployment — authentication happens via OIDC. The only thing to confirm is that the IAM role ARN in `.github/workflows/deploy.yml` matches the `github_actions_role_arn` Terraform output.

Push to `main` and watch the **Actions** tab — each push triggers an SSM-based redeploy.

---

## Security Decisions

A few choices in this repo were deliberate trade-offs, documented here so the reasoning isn't lost:

- **No SSH access for CI/CD.** Deployment uses AWS SSM `send-command`, authenticated through a GitHub OIDC token exchanged for short-lived AWS credentials. No SSH key or AWS access key is stored as a GitHub secret.
- **GitHub Actions IP allowlisting was considered and rejected.** GitHub's runner IP ranges are large, change frequently, and runners have been observed using IPs outside the published ranges — making a security-group allowlist both impractical to maintain and unreliable. SSM avoids the problem entirely by requiring no inbound connection at all.
- **Port 22 is restricted to a single admin IP**, kept open only for manual debugging — not used by any automated process.
- **Database and backend ports are not published to the host** — only nginx (`:80`) is reachable from outside the container network.
- **State files (`*.tfstate`) and credentials are gitignored** — Terraform state is never committed, since it can contain sensitive resource metadata.

---

## Notable Issues Encountered (and Fixes)

| Issue | Root Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` on first connection | SSH was attempted against an instance with no key pair attached (`KeyName: None`) — wrong instance entirely | Identified the correct instance via `aws ec2 describe-instances`; corrected the target IP |
| SSH timing out | Default security group only allowed traffic from within the same security group, not the internet | Added an explicit ingress rule scoped to the admin's IP |
| `No package matching 'docker-ce' is available` | Docker's apt repo was registered with `arch=x86_64` (Ansible fact naming) instead of Debian's expected `arch=amd64` | Used `dpkg --print-architecture` to resolve the correct value before writing the repo definition |
| `permission denied ... docker.sock` | User was added to the `docker` group mid-playbook-run, but group membership doesn't take effect until a new session | Ran the container-boot task as root (`become: true`) instead of waiting on group propagation |
| `404 page not found` on the deployed app | Request was reaching the Go backend correctly — the app simply had no route registered at `/`, only at `/api/v1/health` | Hit the correct route; confirmed via container logs and source inspection, not guesswork |
| `InvalidGroup.NotFound` on `terraform apply` | The instance had been running in AWS's **default VPC** (no `subnet_id` set originally), while the new security group lived in a custom VPC — two different networks | Added `subnet_id`, forcing a clean instance replacement into the correct VPC |
| CI/CD deploy step timing out | GitHub-hosted runners use rotating, unpredictable IPs not covered by any static security-group rule | Replaced SSH-based deploys with OIDC-authenticated AWS SSM commands, removing the network dependency entirely |

---

## License

MIT — see `LICENSE`.
