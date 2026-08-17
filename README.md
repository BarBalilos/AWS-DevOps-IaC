# AWS DevOps Rolling Project — Assignment 2: Terraform + Ansible

## Architecture

A simple 3-tier application deployed on AWS, provisioned entirely with Terraform and configured entirely with Ansible (no manual console setup).

```text
                          Internet
                             |
                      [Internet Gateway]
                             |
                   Public Subnet (10.0.1.0/24)
                             |
                  ┌───────────────────────┐
                  │   frontend (nginx)    │  <- public IP, only server exposed to internet
                  │   also acts as NAT    │     for the private subnets (see "NAT instance" below)
                  └───────────────────────┘
                             |
                (VPC-internal routing only)
                    /                    \
   Private Subnet A (10.0.2.0/24)   Private Subnet B (10.0.3.0/24)
        ┌───────────────────┐         ┌───────────────────┐
        │  backend (Flask)  │         │  worker (Flask)   │
        │  port 5000, /api/ │         │ port 5001, /upload │
        └───────────────────┘         └───────────────────┘
                 |                             |
                 v                             v
          [RDS PostgreSQL]           [S3 bucket] + [SNS topic]
```

- **frontend**: nginx reverse proxy. Routes `/api/*` to backend, `/upload` to worker, everything else returns a static message. Public IP, only server open to the internet (port 80 + SSH from admin IP).
- **backend**: Flask app storing/reading `records` in Postgres (RDS). Private subnet, no direct internet access.
- **worker**: Flask app handling file uploads to S3 and publishing SNS notifications on upload. Private subnet, no direct internet access.
- **RDS (PostgreSQL)**: single instance, reachable only from backend and worker security groups.
- **S3 bucket**: stores uploaded files, private (no public access), versioned.
- **SNS topic**: email notification on every successful upload.

## Components created by Terraform (`terraform/`)

- VPC (`10.0.0.0/16`), 1 public subnet, 2 private subnets, Internet Gateway, public/private route tables
- 4 security groups (frontend, backend, worker, RDS) — each scoped to the minimum access it needs
- 3 EC2 instances (frontend, backend, worker), Amazon Linux 2023
- IAM role + instance profile attached to all 3 instances, granting `s3:PutObject/GetObject/ListBucket` on the app bucket and `sns:Publish` on the app topic (so the app never needs hardcoded AWS keys)
- RDS PostgreSQL instance + subnet group
- S3 bucket (private, versioned)
- SNS topic + email subscription

Outputs (`terraform output`): `frontend_public_ip`, `backend_private_ip`, `worker_private_ip`, `rds_endpoint`, `s3_bucket_name`, `sns_topic_arn`.

## Actions performed by Ansible (`ansible/`)

Run in this order via `playbook.yml`:

1. **nat** (frontend only) — enables IP forwarding and adds an iptables MASQUERADE rule so backend/worker (which have no direct internet route) can reach the internet through the frontend instance. Persisted via a systemd unit (`nat-masquerade.service`) so it survives reboots.
2. **common** (all 3 servers) — updates packages, installs git/unzip/htop, creates `/opt/app`, sets timezone to UTC.
3. **nginx** (frontend only) — installs nginx, deploys the reverse-proxy config (`/api/` → backend:5000, `/upload` → worker:5001).
4. **backend** (backend only) — installs Python3, copies `app.py`/`requirements.txt`, creates a venv, installs dependencies, deploys a systemd service (`backend.service`) with DB connection env vars.
5. **worker** (worker only) — same pattern as backend, deploys `worker.service` with `AWS_REGION`/`S3_BUCKET`/`SNS_TOPIC_ARN` env vars.

## How to run Terraform

```powershell
cd terraform
terraform init
# Copy terraform.tfvars.example to terraform.tfvars and fill in real values (see "Secrets" below)
terraform plan
terraform apply
```

To tear everything down:

```powershell
terraform destroy
```

## How to run Ansible

Requires WSL (Ansible doesn't run natively on Windows).

```bash
cd ansible
# Copy inventory.ini.example to inventory.ini and fill in real IPs from `terraform output`
# Copy group_vars/all.yml.example to group_vars/all.yml and fill in real DB/S3/SNS values
export ANSIBLE_CONFIG=./ansible.cfg
ansible all -m ping          # sanity check connectivity first
ansible-playbook playbook.yml
```

## Variables required

**Terraform** (`terraform/terraform.tfvars`):
`aws_region`, `project_name`, `key_pair_name` (existing EC2 key pair), `ssh_allowed_cidr` (your IP as `x.x.x.x/32`), `db_name`, `db_username`, `db_password`, `notification_email`.

**Ansible** (`ansible/inventory.ini` + `ansible/group_vars/all.yml`):
Frontend/backend/worker IPs (from `terraform output`), SSH key path, `db_host`/`db_port`/`db_name`/`db_user`/`db_password` (must match the Terraform RDS values), `s3_bucket_name`, `sns_topic_arn`, `aws_region`.

## Secrets handling

Nothing sensitive is committed to git. `.gitignore` excludes: `terraform.tfvars`, `*.tfstate*`, `inventory.ini`, `group_vars/all.yml`, and the `.pem` SSH key (kept outside the repo entirely, in `~/.ssh/`). Only the `.example` versions of these files are committed, with placeholder values, documenting the required format for anyone cloning the repo.

AWS credentials for Terraform/AWS CLI come from `aws configure` (IAM user access key), never hardcoded. The EC2 instances themselves use an IAM instance profile (no access keys on disk) to reach S3/SNS.

## How the system is verified working

```bash
curl http://<frontend_public_ip>/api/health      # {"status":"ok"}
curl http://<frontend_public_ip>/api/records      # [] or existing records
curl -X POST -F "file=@somefile.txt" http://<frontend_public_ip>/upload   # {"status":"uploaded","key":"somefile.txt"}
aws s3 ls s3://<s3_bucket_name>/                  # confirms the file landed in S3
```

An email notification should also arrive at the address subscribed to the SNS topic on every successful upload.

## Stopping/starting the environment

EC2 instances can be stopped from the console to avoid any charges. On restart:

1. Start the 3 instances.
2. `terraform apply -refresh-only` in `terraform/`, then `terraform output` — the frontend's public IP changes on every stop/start (no Elastic IP), backend/worker private IPs stay the same.
3. Update `inventory.ini`'s frontend IP (3 spots: the host line and both `ProxyCommand` jump-host references).
4. `ansible all -m ping` to confirm connectivity before running the playbook again.

## Troubleshooting notes / issues hit during this build

- **AMI pitfall**: the Terraform AMI lookup filter `al2023-ami-*-x86_64` also matches the ECS-Optimized variant of Amazon Linux 2023, which ships with Docker pre-installed. Docker rewrites the kernel's iptables `FORWARD` chain on startup, which silently broke the NAT setup below (packets were being dropped even though the MASQUERADE rule looked correct). Fixed by tightening the filter to `al2023-ami-2023.*-x86_64`, which excludes the ECS variant.
- **NAT for private subnets**: backend/worker have no NAT Gateway (kept out to avoid ~$32/month for a course project). Instead, the frontend instance itself acts as a NAT: `source_dest_check = false` on the frontend EC2 instance, the private route table's default route (`0.0.0.0/0`) points at frontend's network interface, and Ansible's `nat` role enables IP forwarding + adds an iptables MASQUERADE rule on the frontend.
- **Security groups apply to forwarded traffic too**: the frontend's security group needed an explicit ingress rule allowing traffic from the private subnet CIDRs — security groups filter all traffic through an ENI, including traffic just being routed through, not only traffic destined for the instance itself.
- **SSH into private-subnet hosts**: done via `ProxyCommand` through the frontend as a jump host, since backend/worker have no public IP.
- Standing up a security group with `lifecycle { create_before_destroy = true }` requires `name_prefix` instead of a fixed `name` (AWS won't allow two SGs with the identical name to exist simultaneously in one VPC, which happens briefly during the swap).

## Screenshots

(Add terminal screenshots showing `terraform apply`, `terraform output`, `ansible-playbook playbook.yml` succeeding, and the `curl` tests above, per the assignment's submission requirements.)
