#!/usr/bin/env sh
# ScyllaDB restore: pull a chosen backup tag's sstable files back from S3
# and load them into the live cluster via `nodetool refresh`.
#
# Scope and assumptions (read before running):
#   - Restores onto the SAME live cluster the backup was taken from, into
#     tables that still exist. This is a "recover recent data loss on a
#     running cluster" tool, not a full disaster-recovery / new-cluster
#     restore. Backup paths encode the source table's on-disk directory
#     name (which includes ScyllaDB's internal table UUID) — if the table
#     was dropped and recreated since the backup, that UUID won't match
#     anything live, and this script will skip it with a warning. Recreate
#     the table first (its `schema.cql` is included in the backup, right
#     alongside the sstables in S3) if that happens.
#   - Only restores one keyspace at a time (default: "demo") — deliberately
#     does not touch system/system_schema/system_distributed by default,
#     since blindly overwriting those on a live cluster is how you actually
#     break it further.
#   - No `tar`, same as backup.sh: streams each file individually via
#     `aws s3 cp - | kubectl exec -i ... cat`.
set -eu

NAMESPACE="${NAMESPACE:-scylla}"
BUCKET="${SCYLLA_BACKUP_BUCKET:?SCYLLA_BACKUP_BUCKET env var required}"
TAG="${BACKUP_TAG:?BACKUP_TAG env var required (e.g. backup-20260826073528)}"
KEYSPACE="${RESTORE_KEYSPACE:-demo}"

echo "== ScyllaDB restore: s3://$BUCKET/$TAG/ -> keyspace '$KEYSPACE' =="

PODS=$(kubectl get pods -n "$NAMESPACE" -l app=scylla -o jsonpath='{.items[*].metadata.name}')
if [ -z "$PODS" ]; then
  echo "No pods found with label app=scylla in namespace $NAMESPACE" >&2
  exit 1
fi

for pod in $PODS; do
  prefix="$TAG/$pod/$KEYSPACE/"
  # List table directories (S3 "common prefixes" under this pod/keyspace).
  TABLE_DIRS=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix" --delimiter "/" \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null || true)

  if [ -z "$TABLE_DIRS" ] || [ "$TABLE_DIRS" = "None" ]; then
    echo "-- $pod: no backed-up tables found under s3://$BUCKET/$prefix, skipping --"
    continue
  fi

  for table_prefix in $TABLE_DIRS; do
    table_dir=$(basename "$table_prefix") # e.g. "users-6f3a2b40817211f0..."
    target="/var/lib/scylla/data/$KEYSPACE/$table_dir"

    if ! kubectl exec -n "$NAMESPACE" "$pod" -- test -d "$target" >/dev/null 2>&1; then
      echo "-- $pod: $KEYSPACE/$table_dir does not exist live — skipping." \
           "If this table was dropped and recreated, restore its schema" \
           "from $prefix$table_dir/schema.cql first, then rerun. --" >&2
      continue
    fi

    table_name=$(echo "$table_dir" | sed -E 's/-[0-9a-f]{32}$//')
    echo "-- $pod: restoring $KEYSPACE.$table_name into $target --"

    FILES=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$table_prefix" \
      --query 'Contents[].Key' --output text)
    for key in $FILES; do
      fname=$(basename "$key")
      case "$fname" in
        manifest.json|schema.cql) continue ;; # metadata, not sstable data
      esac
      echo "   restoring $fname"
      aws s3 cp "s3://$BUCKET/$key" - | kubectl exec -i -n "$NAMESPACE" "$pod" -- sh -c "cat > '$target/$fname'"
    done

    echo "-- $pod: nodetool refresh $KEYSPACE $table_name --"
    kubectl exec -n "$NAMESPACE" "$pod" -- nodetool refresh "$KEYSPACE" "$table_name"
  done
done

echo "== Restore from $TAG complete. Verify with a SELECT before trusting it. =="
