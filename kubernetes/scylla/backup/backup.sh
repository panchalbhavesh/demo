#!/usr/bin/env sh
# ScyllaDB backup: nodetool snapshot on every pod, stream the snapshot
# files straight to S3, then clear the snapshot.
#
# Why streaming via `kubectl exec ... cat | aws s3 cp -` instead of tar:
# the official scylladb/scylla image has no tar binary (hit this earlier
# with `kubectl cp` too), so we can't archive inside the pod. Streaming
# each sstable file individually avoids needing tar anywhere.
#
# Runs from outside the scylla pods (a CronJob pod, or a CI runner) —
# needs `kubectl` (pointed at the cluster) and `aws` CLI available, and an
# identity that can both exec into scylla pods and write to the S3 bucket.
set -eu

NAMESPACE="${NAMESPACE:-scylla}"
BUCKET="${SCYLLA_BACKUP_BUCKET:?SCYLLA_BACKUP_BUCKET env var required}"
TAG="backup-$(date -u +%Y%m%d%H%M%S)"

echo "== ScyllaDB backup: $TAG -> s3://$BUCKET/$TAG/ =="

PODS=$(kubectl get pods -n "$NAMESPACE" -l app=scylla -o jsonpath='{.items[*].metadata.name}')
if [ -z "$PODS" ]; then
  echo "No pods found with label app=scylla in namespace $NAMESPACE" >&2
  exit 1
fi

for pod in $PODS; do
  echo "-- $pod: taking snapshot --"
  kubectl exec -n "$NAMESPACE" "$pod" -- nodetool snapshot -t "$TAG" >/dev/null

  # Find every snapshot dir this pod just created (one per keyspace/table).
  SNAP_DIRS=$(kubectl exec -n "$NAMESPACE" "$pod" -- find /var/lib/scylla/data -type d -name "$TAG")

  for snap_dir in $SNAP_DIRS; do
    # snap_dir looks like: /var/lib/scylla/data/<keyspace>/<table-uuid>/snapshots/<tag>
    ks_table=$(echo "$snap_dir" | sed -E 's#^/var/lib/scylla/data/([^/]+)/([^/]+)/snapshots/.*#\1/\2#')

    FILES=$(kubectl exec -n "$NAMESPACE" "$pod" -- find "$snap_dir" -type f)
    for f in $FILES; do
      fname=$(basename "$f")
      dest="s3://$BUCKET/$TAG/$pod/$ks_table/$fname"
      echo "   uploading $f -> $dest"
      kubectl exec -n "$NAMESPACE" "$pod" -- cat "$f" | aws s3 cp - "$dest" --only-show-errors
    done
  done

  echo "-- $pod: clearing snapshot --"
  kubectl exec -n "$NAMESPACE" "$pod" -- nodetool clearsnapshot -t "$TAG" >/dev/null
done

echo "== Backup $TAG complete: s3://$BUCKET/$TAG/ =="
