# ScyllaDB on EKS

This is my submission for the take-home assessment: a ScyllaDB cluster on
Amazon EKS, provisioned with Terraform, plus a scheduled backup pipeline to
S3 that also runs as a GitHub Action. Everything below covers what's built,
why I made the choices I did, and what I'd add next if this were going to
production rather than a demo.

Quick summary:

```
Terraform  ─▶  EKS cluster (3 AZs)  ─▶  ScyllaDB StatefulSet (3 nodes)
                                              │
                                   nodetool snapshot + kubectl exec
                                              ▼
                                    S3 (backups, encrypted, versioned)
                                              ▲
                              in-cluster CronJob  or  GitHub Actions
```

## What this actually is

```
Internet
   │
   ▼
EKS API (public, IAM-authenticated) ── kubectl / terraform
   │
   ▼
┌─────────────────────────── VPC 10.40.0.0/16 (us-east-2) ───────────────────────────┐
│                                                                                     │
│   AZ us-east-2a          AZ us-east-2b          AZ us-east-2c                      │
│   ┌───────────┐          ┌───────────┐          ┌───────────┐                      │
│   │ EC2 node  │          │ EC2 node  │          │ EC2 node  │   1 managed node      │
│   │ m7i-flex  │          │ m7i-flex  │          │ m7i-flex  │   group, 3 nodes,     │
│   │  .large   │          │  .large   │          │  .large   │   fixed size          │
│   │           │          │           │          │           │                      │
│   │ scylla-0  │          │ scylla-1  │          │ scylla-2  │   StatefulSet pod     │
│   │ + 5Gi gp3 │          │ + 5Gi gp3 │          │ + 5Gi gp3 │   per AZ (spread       │
│   │   EBS PVC │          │   EBS PVC │          │   EBS PVC │   via topology        │
│   └───────────┘          └───────────┘          └───────────┘   constraints)        │
│                                                                                     │
│   Cluster Autoscaler (idle — min=max=desired=3, nothing to scale yet)              │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                         nodetool snapshot + kubectl exec,
                         scheduled (CronJob) or on-demand (CI)
                                    ▼
                        S3 bucket (versioned, encrypted,
                        public access blocked)
```

## Stack and why

| Layer | Choice | Why |
|---|---|---|
| IaC | Terraform | Declarative, state-tracked, plan-before-apply — safer than clicking around the console or scripting `eksctl`. |
| Cluster | EKS 1.36, managed node group | Managed control plane, one fixed-size node group (3× `m7i-flex.large`) keeps cost predictable for a demo. |
| Autoscaling | Cluster Autoscaler via Helm, EKS Pod Identity | Installed and wired but inert (min=max=desired=3) — shows the capability without paying for it. |
| Storage driver | `aws-ebs-csi-driver` EKS addon, Pod Identity | Needed for any PersistentVolume at all; ScyllaDB's data directory is backed by EBS gp3, not local NVMe (see tradeoffs below). |
| ScyllaDB | Plain Kubernetes `StatefulSet` (not the ScyllaDB Operator) | Fewer moving parts for a demo — no cert-manager, no Operator CRDs to install first. Trade-off: no automated repairs/backups/node-replace (see below). |
| Networking | Public EKS API endpoint, no CIDR restriction | Chosen explicitly so Terraform/kubectl can run from a laptop outside the VPC, without a bastion/VPN. IAM auth still gates actual access. |
| Auth to AWS | EKS Pod Identity (not IRSA) | Newer, simpler mechanism — no OIDC provider needed for the roles actually in use (EBS CSI driver, Cluster Autoscaler). |

## Repo layout

```
(repo root)
  terraform/
    modules/cluster/   Reusable EKS module: VPC (3 AZ), KMS, EKS control
                        plane, one managed node group, IAM roles for the
                        EBS CSI driver + Cluster Autoscaler via Pod Identity.
    source/            Root module for the ScyllaDB "source" cluster.
                        Instantiates modules/cluster, installs Cluster
                        Autoscaler via Helm, and provisions the S3 backup
                        bucket + IAM role (backup.tf), plus the optional
                        GitHub OIDC setup for the backup workflow
                        (github-oidc.tf).
  kubernetes/
    scylla/            StatefulSet, headless Service, PodDisruptionBudget,
                        StorageClass, namespace, sample data — the actual
                        database.
    scylla/backup/     Backup tooling: script, RBAC, CronJob (in-cluster
                        scheduled backups). The GitHub Actions equivalent
                        lives under .github/workflows/.
```

## Deploy

```bash
cd terraform/source
terraform init      # no prompts, backend is hardcoded to an existing S3 bucket
terraform plan
terraform apply     # creates the EKS cluster, node group, Cluster Autoscaler, S3 bucket

aws eks update-kubeconfig --name scylla-demo-source --region us-east-2 --alias source

kubectl apply --server-side -f=kubernetes/scylla/01-storageclass.yaml
kubectl apply --server-side -f=kubernetes/scylla/02-namespace.yaml
kubectl apply --server-side -f=kubernetes/scylla/04-scylla-statefulset.yaml

kubectl -n scylla rollout status statefulset/scylla --timeout=10m
kubectl exec -n scylla scylla-0 -- nodetool status   # expect 3 UN rows
```

Clean up:

```bash
kubectl delete statefulset scylla -n scylla
kubectl delete pvc -l app=scylla -n scylla   # PVCs aren't deleted automatically
```

### Load sample data and confirm it's real

`kubernetes/scylla/sample-data.cql` creates a `demo` keyspace with a couple
of small tables and rows. It uses `SimpleStrategy` rather than
`NetworkTopologyStrategy`, because the StatefulSet doesn't set
`--endpoint-snitch`, so every node reports under one default datacenter
name — `NetworkTopologyStrategy` would need that real DC name.

```bash
kubectl exec -i -n scylla scylla-0 -- sh -c 'cat > /tmp/sample-data.cql' < kubernetes/scylla/sample-data.cql
kubectl exec -n scylla scylla-0 -- cqlsh -f /tmp/sample-data.cql
kubectl exec -n scylla scylla-0 -- cqlsh -e "SELECT * FROM demo.users;"
```

Confirmed output from an actual run:

```
 user_id                              | created_at                      | email             | name
--------------------------------------+----------------------------------+-------------------+--------------
 6630de9f-5ce6-478e-bf7d-715dff4ca1ab | 2026-08-26 07:16:36.438000+0000 | alice@example.com | Alice Johnson
 6a621826-8806-4220-89b5-70aac962eef1 | 2026-08-26 07:16:36.440000+0000 |   bob@example.com |     Bob Smith
 420eae1c-c321-483e-bce9-e409e8c734f3 | 2026-08-26 07:16:36.441000+0000 | carla@example.com |   Carla Diaz
 33f4ee70-922b-4441-9786-ef29d7fe7d97 | 2026-08-26 07:16:36.442000+0000 | emma@example.com  |  Emma Wilson
 b4af1d3b-ccf0-4c4b-b76d-3c28dc66f2f7 | 2026-08-26 07:16:36.441000+0000 | david@example.com |   David Chen

(5 rows)
```

## Backup

`kubernetes/scylla/backup/backup.sh` runs `nodetool snapshot` on every
ScyllaDB pod, then streams each resulting sstable file straight to S3
(`kubectl exec ... cat | aws s3 cp -` — no `tar`, since the ScyllaDB image
doesn't ship one), then clears the snapshot. It runs two ways from the same
script, both authenticating to AWS with zero static keys:

1. **In-cluster CronJob** (`kubernetes/scylla/backup/cronjob.yaml`) — daily
   at 03:00 UTC, via EKS Pod Identity.
2. **GitHub Actions workflow** (`.github/workflows/scylla-backup.yml`) —
   manual dispatch or the same daily schedule, via GitHub OIDC → a scoped
   IAM role.

### Deploy the CronJob

```bash
kubectl apply -f kubernetes/scylla/backup/rbac.yaml
kubectl apply -f kubernetes/scylla/backup/configmap.yaml
kubectl apply -f kubernetes/scylla/backup/cronjob.yaml
```

Trigger a manual run to test rather than waiting for the schedule:

```bash
kubectl create job --from=cronjob/scylla-backup scylla-backup-manual -n scylla
kubectl logs -n scylla -l job-name=scylla-backup-manual -f
```

Verify objects landed in S3:

```bash
aws s3 ls s3://scylla-demo-source-backups/ --recursive
```

### Enable the GitHub Actions workflow

1. In `terraform/source/terraform.tfvars`, set `github_repo = "your-org/your-repo"`.
2. `terraform apply` — creates the GitHub OIDC provider, a scoped IAM role
   (S3 access to only this bucket, plus `eks:DescribeCluster`), and an EKS
   access entry mapping that role to the `scylla-backup-ci` Kubernetes
   group (bound to the same restricted Role as the CronJob's
   ServiceAccount — see `rbac.yaml`).
3. Copy the Terraform output `github_actions_backup_role_arn` and add it as
   a GitHub repo secret named `SCYLLA_BACKUP_ROLE_ARN`.
4. Run the workflow from the Actions tab, or wait for its daily schedule.

### Restoring (manual — not automated in this demo)

Backups land at `s3://scylla-demo-source-backups/<tag>/<pod>/<keyspace>/<table>/`.
To restore: download the sstable files for a table, copy them into the
target pod's `/var/lib/scylla/data/<keyspace>/<table-uuid>/` (same tar-less
streaming trick as backup), then run `nodetool refresh <keyspace> <table>`.
Flagging this as a known gap rather than leaving it undocumented.

## Design notes

- **Terraform for infra, kubectl for the database resource.** The ScyllaDB
  StatefulSet is applied with `kubectl`, not Terraform — it's
  application-layer state, and if this project later adopts the ScyllaDB
  Operator, its CRDs wouldn't exist yet at Terraform plan time
  (chicken-and-egg problem with `kubernetes_manifest` on custom resources).
  Splitting infra (Terraform) from app-layer objects (kubectl) sidesteps
  that cleanly.
- **Pod Identity instead of IRSA.** Pod Identity is the newer AWS mechanism
  for giving pods IAM permissions — no OIDC provider to manage, simpler
  trust policy (`pods.eks.amazonaws.com` instead of a federated OIDC
  principal). IRSA is still supported by the underlying module but unused
  here.
- **Why not the ScyllaDB Operator.** It's the production-recommended path
  (handles rolling upgrades, repairs, node replacement, and backup
  scheduling declaratively) but requires cert-manager plus its own Helm
  install and CRDs — extra moving parts not worth it for a single demo
  cluster. The trade-off is explicit and documented below.
- **ScyllaDB-on-k8s gotcha handled here.** ScyllaDB needs
  `--broadcast-rpc-address` set explicitly alongside `--rpc-address=0.0.0.0`,
  or it crash-loops with `bad_configuration_error`. Baked into the
  StatefulSet's pod IP-based args.
- **Non-root container vs. a freshly mounted EBS volume.** A fresh EBS
  volume mounts as `root:root`, but the ScyllaDB image runs as a non-root
  user — without a pod-level `fsGroup`, it can't create
  `/var/lib/scylla/data` and crash-loops with a permission error. Set in
  the StatefulSet's pod `securityContext`.

## What's deliberately cut (demo vs. production)

| Cut for this demo | What production would need instead |
|---|---|
| No authentication (`AllowAllAuthenticator`) | `PasswordAuthenticator` + `CassandraAuthorizer`, secrets management |
| gp3 EBS storage, shared node group | Dedicated, tainted node pool on instance types with local NVMe (e.g. `i4i.2xlarge`), per ScyllaDB's own reference architecture |
| No ScyllaDB Manager (repairs, restore automation) | Manager server + `ScyllaDBManagerTask` — backups themselves are already handled by the CronJob/GitHub Actions pipeline above; restore is manual for now |
| No monitoring | Prometheus + Grafana (ScyllaDB Operator ships dashboards for this) |
| Public EKS API endpoint, unrestricted | Private-only endpoint + bastion/VPN/SSM, or restricted CIDRs |
| Single AZ-spread StatefulSet, manual scaling | ScyllaDB Operator for declarative scaling, upgrades, node replacement |
| One region, one cluster | A second ("target") cluster + migration tooling between the two — not built yet |

## Not yet built

- Target cluster (migration destination) and cluster-to-cluster migration
  tooling — the current backup pipeline moves data to S3, not to another
  live cluster.
- Restore automation (backup path is scripted and verified; restore is a
  manual, documented procedure — see "Restoring" above).
- ScyllaDB Manager and a monitoring/observability stack.
