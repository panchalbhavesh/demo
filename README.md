# ScyllaDB on EKS

This is my submission for the take-home assessment. It's a ScyllaDB cluster on Amazon EKS, set up with Terraform, plus a scheduled backup pipeline to S3 that also runs as a GitHub Action. Below I cover what's built, why I made the choices I did, and what I would add next if this was going to production instead of a demo.

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
│   Cluster Autoscaler (idle, min=max=desired=3, nothing to scale yet)               │
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
| IaC | Terraform | Declarative, keeps state, lets you plan before you apply. Safer than clicking around the console or scripting `eksctl`. |
| Cluster | EKS 1.36, managed node group | Managed control plane, one fixed-size node group (3x `m7i-flex.large`) keeps cost predictable for a demo. |
| Autoscaling | Cluster Autoscaler via Helm, EKS Pod Identity | Installed and wired up but not doing anything yet (min=max=desired=3). Shows the capability without paying for it. |
| Storage driver | `aws-ebs-csi-driver` EKS addon, Pod Identity | Needed for any PersistentVolume at all. ScyllaDB's data directory sits on EBS gp3, not local NVMe (see the tradeoffs table below). |
| ScyllaDB | Plain Kubernetes `StatefulSet`, not the ScyllaDB Operator | Fewer moving parts for a demo. No cert-manager, no Operator CRDs to install first. Tradeoff: no automated repairs, backups, or node replace (see below). |
| Networking | Public EKS API endpoint, no CIDR restriction | Chosen so Terraform and kubectl can run from a laptop outside the VPC, without a bastion or VPN. IAM auth still gates actual access. |
| Auth to AWS | EKS Pod Identity, not IRSA | Newer, simpler mechanism. No OIDC provider needed for the roles actually in use (EBS CSI driver, Cluster Autoscaler). |

## Repo layout

```
(repo root)
  terraform/
    modules/cluster/   Reusable EKS module: VPC (3 AZ), KMS, EKS control
                        plane, one managed node group, IAM roles for the
                        EBS CSI driver and Cluster Autoscaler via Pod Identity.
    source/            Root module for the ScyllaDB "source" cluster.
                        Instantiates modules/cluster, installs Cluster
                        Autoscaler via Helm, and sets up the S3 backup
                        bucket and IAM role (backup.tf), plus the optional
                        GitHub OIDC setup for the backup workflow
                        (github-oidc.tf).
  kubernetes/
    scylla/            StatefulSet, headless Service, PodDisruptionBudget,
                        StorageClass, namespace, sample data. The actual
                        database.
    scylla/backup/     Backup tooling: script, RBAC, CronJob (in-cluster
                        scheduled backups). The GitHub Actions version
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
kubectl delete pvc -l app=scylla -n scylla   # PVCs don't get deleted on their own
```

### Load sample data and check it's real

`kubernetes/scylla/sample-data.cql` creates a `demo` keyspace with a couple of small tables and rows. It uses `SimpleStrategy` instead of `NetworkTopologyStrategy`, because the StatefulSet doesn't set `--endpoint-snitch`, so every node reports under one default datacenter name. `NetworkTopologyStrategy` would need that real DC name.

```bash
kubectl exec -i -n scylla scylla-0 -- sh -c 'cat > /tmp/sample-data.cql' < kubernetes/scylla/sample-data.cql
kubectl exec -n scylla scylla-0 -- cqlsh -f /tmp/sample-data.cql
kubectl exec -n scylla scylla-0 -- cqlsh -e "SELECT * FROM demo.users;"
```

Actual output from a real run:

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

`kubernetes/scylla/backup/backup.sh` runs `nodetool snapshot` on every ScyllaDB pod, then streams each sstable file straight to S3 (`kubectl exec ... cat | aws s3 cp -`, no `tar`, since the ScyllaDB image doesn't ship one), then clears the snapshot. It runs two ways from the same script, both authenticating to AWS with zero static keys:

1. **In-cluster CronJob** (`kubernetes/scylla/backup/cronjob.yaml`), daily at 3 in the morning UTC, via EKS Pod Identity.
2. **GitHub Actions workflow** (`.github/workflows/scylla-backup.yml`), manual dispatch or the same daily schedule, via GitHub OIDC to a scoped IAM role.

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

Check the objects landed in S3:

```bash
aws s3 ls s3://scylla-demo-source-backups/ --recursive
```

### Enable the GitHub Actions workflow

1. In `terraform/source/terraform.tfvars`, set `github_repo = "your-org/your-repo"`.
2. `terraform apply` creates the GitHub OIDC provider, a scoped IAM role (S3 access to only this bucket, plus `eks:DescribeCluster`), and an EKS access entry mapping that role to the `scylla-backup-ci` Kubernetes group (bound to the same restricted Role as the CronJob's ServiceAccount, see `rbac.yaml`).
3. Copy the Terraform output `github_actions_backup_role_arn` and add it as a GitHub repo secret named `SCYLLA_BACKUP_ROLE_ARN`.
4. Run the workflow from the Actions tab, or wait for its daily schedule.

### Restoring

`kubernetes/scylla/backup/restore.sh` pulls a chosen backup tag's sstable files back from S3 and loads them via `nodetool refresh`, using the same tar-less streaming approach as backup. It then runs `nodetool repair` on the keyspace across every pod before calling it done. A restore could land data on only some replicas (say a pod was unreachable during the original backup), so this reconciles any drift automatically instead of leaving it for someone to spot later through mismatched `SELECT COUNT(*)` results (I hit this myself, see "Known limitations" below). It runs the same way as backup, either in-cluster or through a dedicated GitHub Actions workflow (`.github/workflows/scylla-restore.yml`).

Scope: this restores into a live keyspace and table that already exist. The keyspace and tables have to exist before `restore.sh` runs, it never creates schema on its own. The live target directory is looked up by table name, not by matching the backup's exact UUID-suffixed directory, so this works both for a "same table, never touched" restore and a full disaster-recovery restore where the table was dropped and recreated (or the whole cluster's storage was wiped) and got a brand new internal UUID. If a table doesn't exist live at all, the script skips it with a warning instead of quietly doing nothing. Its `schema.cql` sits right next to the sstables in S3, so you can recreate it and run the script again.

### Tested: full disaster recovery (pods and PVCs wiped, restored from S3 alone)

I went further than just "recover a recent mistake" and actually destroyed the cluster's storage completely, then rebuilt it from nothing but the S3 backup, to prove the pipeline is a real disaster-recovery path and not just an undo button:

```bash
kubectl delete statefulset scylla -n scylla
kubectl delete pvc -n scylla -l app=scylla        # wipes all 3 EBS volumes
kubectl apply -f kubernetes/scylla/04-scylla-statefulset.yaml
kubectl -n scylla rollout status statefulset/scylla --timeout=10m

# Keyspace and tables don't survive a PVC wipe, recreate them from the
# backup's own schema.cql before restore.sh has anything to target:
kubectl exec -n scylla scylla-0 -- cqlsh -e \
  "CREATE KEYSPACE IF NOT EXISTS demo WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3};"
aws s3 cp s3://scylla-demo-source-backups/<tag>/scylla-0/demo/users-<uuid>/schema.cql -
aws s3 cp s3://scylla-demo-source-backups/<tag>/scylla-0/demo/events-<uuid>/schema.cql -
# apply each printed CREATE TABLE statement with its own cqlsh -e "..." call

gh workflow run scylla-restore.yml -f backup_tag=<tag> -f keyspace=demo -f confirm=restore
```

Checked afterward on all three pods separately, not just the one that ran the restore:

```
== scylla-0 ==
 count
-------
     5
 count
-------
     3
```
(same counts on scylla-1 and scylla-2 too, confirmed with `nodetool repair` reconciling all replicas)

### Known limitations

- **`nodetool refresh` only loads sstables from the table's `upload/` subfolder, not the table's root folder.** This was the real reason restore would finish with zero errors but no data showed up. Scylla's own log showed `Loaded 0 SSTables` even though `nodetool refresh` reported success and `nodetool repair` ran clean right after. `restore.sh` now streams files into `<table-dir>/upload/` before calling refresh. I confirmed this by hand: same files, same refresh command, zero rows with files sitting in the table root, correct data back once I moved them into `upload/` and ran refresh again.
- **`TRUNCATE` permanently blocks restoring pre-truncation backups for that same, never-recreated table.** ScyllaDB (like Cassandra) keeps a truncation timestamp per table. Any data written at or before that point stays hidden at read time even if the sstable files are physically there, and there's no supported way to undo it short of dropping and recreating the table. This is a separate issue from the `upload/` one above, and only comes up if you truncate without also recreating the table. A fresh disaster-recovery restore (drop the PVC, recreate the table) gets a new table UUID and isn't affected by this.
- **Deleting sstable files directly while ScyllaDB is running is unsafe.** The process keeps its own in-memory list of a table's sstables and doesn't rescan the folder on its own, so removing files from under a live process risks read errors instead of a clean empty result. Stop the pod first (or let Kubernetes restart it) before removing files, not after.

Manually:
```bash
NAMESPACE=scylla SCYLLA_BACKUP_BUCKET=scylla-demo-source-backups \
  BACKUP_TAG=<tag-from-aws-s3-ls> RESTORE_KEYSPACE=demo \
  sh kubernetes/scylla/backup/restore.sh
```

Via GitHub Actions: run the "ScyllaDB restore" workflow from the Actions tab. It needs you to type `restore` into a confirmation input. The workflow has no schedule trigger and can only be run by hand, since restore overwrites live data.

## Design notes

- **Terraform for infra, kubectl for the database resource.** The ScyllaDB StatefulSet is applied with `kubectl`, not Terraform. It's application-layer state, and if this project later adopts the ScyllaDB Operator, its CRDs wouldn't exist yet at Terraform plan time (a chicken-and-egg problem with `kubernetes_manifest` on custom resources). Keeping infra (Terraform) separate from app-layer objects (kubectl) avoids that cleanly.
- **Pod Identity instead of IRSA.** Pod Identity is the newer AWS mechanism for giving pods IAM permissions. No OIDC provider to manage, simpler trust policy (`pods.eks.amazonaws.com` instead of a federated OIDC principal). IRSA is still supported by the underlying module but not used here.
- **Why not the ScyllaDB Operator.** It's the production-recommended path (handles rolling upgrades, repairs, node replacement, and backup scheduling declaratively) but needs cert-manager plus its own Helm install and CRDs. That's extra moving parts not worth it for a single demo cluster. The tradeoff is written down below.
- **ScyllaDB-on-k8s gotcha handled here.** ScyllaDB needs `--broadcast-rpc-address` set explicitly alongside `--rpc-address=0.0.0.0`, or it crash-loops with `bad_configuration_error`. Baked into the StatefulSet's pod IP-based args.
- **Non-root container vs. a freshly mounted EBS volume.** A fresh EBS volume mounts as `root:root`, but the ScyllaDB image runs as a non-root user. Without a pod-level `fsGroup`, it can't create `/var/lib/scylla/data` and crash-loops with a permission error. Set in the StatefulSet's pod `securityContext`.

## What's deliberately cut (demo vs. production)

| Cut for this demo | What production would need instead |
|---|---|
| No authentication (`AllowAllAuthenticator`) | `PasswordAuthenticator` + `CassandraAuthorizer`, secrets management |
| gp3 EBS storage, shared node group | A dedicated, tainted node pool on instance types with local NVMe (e.g. `i4i.2xlarge`), per ScyllaDB's own reference architecture |
| No ScyllaDB Manager (repairs, more general restore-anywhere tooling) | Manager server + `ScyllaDBManagerTask`, though backup and restore for this specific cluster are already handled by the pipeline above |
| No monitoring | Prometheus + Grafana (ScyllaDB Operator ships dashboards for this) |
| Public EKS API endpoint, unrestricted | Private-only endpoint plus bastion/VPN/SSM, or restricted CIDRs |
| Single AZ-spread StatefulSet, manual scaling | ScyllaDB Operator for declarative scaling, upgrades, node replacement |
| One region, one cluster | A second ("target") cluster plus migration tooling between the two, not built yet |

## Not yet built

- A target cluster (migration destination) and cluster-to-cluster migration tooling. The current backup pipeline moves data to S3, not to another live cluster.
- ScyllaDB Manager and a monitoring/observability stack.
