# AWS benchmark environment

Two temporary EC2 hosts in `ap-northeast-1`, using the AWS CLI profile given as `aws_profile`:

```text
load generator (c7i.4xlarge) -- private HTTP:8080 --> server (c7i.2xlarge)
```

Both hosts share an AZ and cluster placement group. Run roxum, axum, and Go
sequentially on the **same server instance**. This configuration creates the
hosts and network; it does not certify measurement validity. Follow the
[comparison protocol](../protocol.md).

## Resources and access

Default tags are `Purpose=http-benchmark` and `ManagedBy=terraform`; resources
also have identifying names. No `Project` tag is assigned. Check organizational
tagging requirements before provisioning in another account.

- A dedicated VPC, one subnet, internet gateway, and route table.
- On-Demand x86_64 EC2: server 8 vCPUs / 16 GiB, client 16 vCPUs / 32 GiB.
  vCPUs are hardware threads; record the actual CPU topology before assigning
  core budgets. Neither Spot nor burstable CPU-credit instances are used.
- Two encrypted 40 GiB gp3 root volumes, deleted on instance termination.
- One public IPv4 per host for package downloads and SSM; no SSH ingress.
  The only inbound rule is TCP 8080 to the server from the client security group.
  Benchmark traffic must use private IPs. No ALB, NAT Gateway, or SSM tunnel is
  in the measurement path.
- Separate server/client EC2 roles with `AmazonSSMManagedInstanceCore`, and IMDSv2 required.
  The client additionally controls the benchmark server via SSM; command execution
  is restricted to that server and `AWS-RunShellScript`.
- A systemd timer stops each instance four hours after boot. This is a local
  safeguard, not a guaranteed spending cap. It restarts its window on each boot.
  **Stopped instances retain EBS volumes and their charges. Destroy after use.**

The fixed AMI is checked against Amazon-owned AL2023 x86_64 images. OS package
versions are recorded during bootstrap; toolchains are not installed from moving
"latest" URLs. Capture package versions and pin the AMI for repeated experiments.

## Before the first plan

Verify the account identity for that profile, permissions, regional vCPU quota,
and an AZ offering both types. A 24-vCPU On-Demand allocation is needed before
accounting for existing workloads; an offering does not guarantee current
capacity. Confirm cluster placement capacity when provisioning.

Select and record one Amazon Linux 2023 x86_64 AMI matching
`al2023-ami-2023.*-kernel-6.1-x86_64`. The module deliberately has no automatic
"latest AMI" lookup. Copy `example.tfvars` to `local.tfvars`, then fill in the
profile, verified account ID, AZ, and AMI. `allowed_account_ids` prevents using a different
account accidentally. Do not commit account-specific inputs, state, or plan files.

Required local tools: Terraform >= 1.9, AWS CLI, configured profile, and the
Session Manager plugin. Keep `.terraform.lock.hcl` in version control.

From this directory:

```sh
terraform init -lockfile=readonly
terraform fmt -check -recursive
terraform validate
terraform test
terraform plan -input=false -var-file=local.tfvars -out=benchmark.tfplan
terraform show -no-color benchmark.tfplan
```

`terraform test` uses a mocked provider and makes no AWS calls. Review the saved
plan and [cost estimate](cost-estimate.md) before creating resources. Do not apply
with placeholder account, AZ, or AMI values.

## Provisioning and verification

After the plan and costs are approved:

```sh
terraform apply benchmark.tfplan
terraform output -json
```

The `hosts` output gives SSM connection commands for each machine. Use them from
your workstation; interactive SSM sessions are for administration only. On each
host, wait for setup and inspect the scheduled stop:

```sh
sudo cloud-init status --wait
cat /opt/roxum-bench/bootstrap-complete
cat /opt/roxum-bench/os-packages.txt
systemctl list-timers benchmark-stop.timer
```

Capture the AMI, CPU topology, kernel, package versions, clock synchronization,
network limits, descriptor limits, CPU affinity, and environment overrides. Build
all candidates with pinned toolchains before the measurement sequence;
`bash bench/m13/build.sh linux-native` builds all three with the installed tools
and writes a build manifest beside the binaries. This build mode still needs
verification on the target Linux host. Retain
source revision, dirty patch, build commands, lockfiles, and binary hashes.

## Measurement readiness

The [two-host runner](../remote.md) and Linux cgroup controller are implemented,
but their systemd behavior still needs verification on the target Linux host.
Before comparative measurements:

1. Build all three servers and enable the shared `benchmark-remote` startup mode
   in their working directory. They then listen on `0.0.0.0:8080`.
2. Configure the implemented SSM adapter with the server instance ID and a named
   client profile using its instance role. Verify delivery and permissions. Run
   HTTP load generation on the client host only, over private IP.
3. Verify equal CPU/memory limits using the controller's effective cgroup values.
   Record SMT/core assignments. Start with one-core and multicore experiments
   separately; leave headroom for OS and monitoring work.
4. Verify generator CPU/network headroom and EC2 network/packet allowance metrics.
   These C7i sizes have burst network limits; do not interpret a network ceiling
   as an application bottleneck. Increase generator capacity if necessary.
5. Verify A/A noise controls, repeat across time windows, and add constant-rate
   latency sweeps before publishing latency/SLO claims.

Do not select tuning or exclude errors based on which implementation benefits.
The local smoke results are harness validation, not baseline EC2 measurements.

## Cleanup

Save experiment artifacts to the workstation before deleting the hosts. Preserve
Terraform state until cleanup is confirmed.

```sh
terraform plan -destroy -input=false -var-file=local.tfvars -out=destroy.tfplan
terraform show -no-color destroy.tfplan
terraform apply destroy.tfplan
terraform state list
```

This deletes the two instances and their root volumes plus the dedicated network
and IAM resources. Verify completion; the shutdown timer alone is insufficient.

The client IAM role changes the infrastructure plan. Regenerate and review any
previously saved plan before applying; the earlier plan does not include this role.
