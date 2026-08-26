#!/usr/bin/env sh
# ScyllaDB restore: pull a chosen backup tag's sstable files back from S3
# and load them into the live cluster via `nodetool refresh`.
#
# Scope and assumptions (read before running):
#   - Restores onto the SAME live cluster the backup was taken from (same
#     pod names), into tables that already exist — the keyspace/table
#     schema must exist live before this runs (recreate it from the
#     included `schema.cql` in S3, right next to the sstables, if needed).
#   - The live target directory is looked up dynamically by table NAME,
#     not by matching the backup's exact UUID-suffixed directory name.
#     ScyllaDB assigns a new UUID whenever a table is (re)created, so if
#     storage was wiped and the schema recreated from scratch, the new
#     table's UUID will differ from the one baked into the backup's S3
#     path — this still restores correctly onto whatever the CURRENT live
#     directory for that table name is.
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
    table_name=$(echo "$table_dir" | sed -E 's/-[0-9a-f]{32}$//')

    # Look up the CURRENT live directory for this table by name, not by the
    # backup's exact (possibly stale) UUID — handles both "same table,
    # never dropped" and "storage wiped, schema recreated with a new UUID".
    target=$(kubectl exec -n "$NAMESPACE" "$pod" -- sh -c \
      "ls -d /var/lib/scylla/data/$KEYSPACE/${table_name}-* 2>/dev/null | head -1")

    if [ -z "$target" ]; then
      echo "-- $pod: no live directory for $KEYSPACE.$table_name — skipping." \
           "Create the keyspace/table first (schema is at" \
           "$prefix$table_dir/schema.cql in S3), then rerun. --" >&2
      continue
    fi

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

# A restore could plausibly land sstables on only some replicas (e.g. a pod
# was unreachable when this backup was taken, or a partial run failed
# midway). Rather than trust that every node ended up consistent, run an
# anti-entropy repair across the keyspace before declaring success —
# reconciles any drift automatically instead of leaving it for someone to
# notice via mismatched SELECT COUNT(*) results later.
echo "== Repairing $KEYSPACE to reconcile any cross-replica drift =="
for pod in $PODS; do
  echo "-- $pod: nodetool repair $KEYSPACE --"
  kubectl exec -n "$NAMESPACE" "$pod" -- nodetool repair "$KEYSPACE"
done

echo "== Restore from $TAG complete. Verify with a SELECT before trusting it. =="
