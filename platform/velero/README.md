# Velero Backup System

This directory contains the Velero backup configuration for the automation-k8s-stack.

## Overview

Velero provides backup and restore capabilities for Kubernetes cluster resources and persistent volumes. This configuration uses Minio as an S3-compatible backend for storing backups.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                           │
│                                                                       │
│  ┌─────────────┐    ┌─────────────────┐    ┌─────────────────┐      │
│  │   Velero    │───▶│ Backup Storage  │───▶│     Minio       │      │
│  │  Controller │    │    Location     │    │  (velero bucket)│      │
│  └─────────────┘    └─────────────────┘    └─────────────────┘      │
│         │                                                            │
│         ▼                                                            │
│  ┌─────────────┐                                                     │
│  │ Node Agent  │  (Restic for file-level backups)                   │
│  │ (DaemonSet) │                                                     │
│  └─────────────┘                                                     │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Running k3d cluster (`make cluster-up`)
- Minio object storage (`make minio-up`)
- Helm 3.x installed

## Installation

```bash
# Install Velero (idempotent)
make velero-up

# Check status
make velero-status

# Uninstall
make velero-down
```

## Directory Structure

```
platform/velero/
├── README.md                    # This file
├── values.yaml                  # Velero Helm values
└── resources/
    ├── namespace.yaml           # velero namespace
    ├── secret.yaml              # Minio credentials
    └── backup-schedule.yaml     # Scheduled backup config
```

## Configuration

### k3d Optimizations

| Setting | Value | Reason |
|---------|-------|--------|
| Storage Backend | Minio S3 | Local object storage |
| Volume Snapshots | Disabled | k3d local-path doesn't support CSI |
| Node Agent | Enabled | Restic for file-level backups |
| Backup Retention | 7 days | Short retention for dev |
| Schedule | Daily at 2 AM | Automatic backups |

### Backup Storage

Backups are stored in the `velero` bucket in Minio:
- **Endpoint**: `http://minio.minio.svc.cluster.local:9000`
- **Bucket**: `velero`
- **Credentials**: From `velero-minio-credentials` secret

### Scheduled Backups

The default schedule backs up all namespaces except system namespaces:
- **Included**: All user namespaces
- **Excluded**: `kube-system`, `kube-public`, `kube-node-lease`, `velero`
- **Retention**: 7 days (168 hours)

## Usage

### Create a Manual Backup

```bash
# Backup a specific namespace
kubectl exec -n velero deploy/velero -- velero backup create my-backup \
  --include-namespaces my-namespace

# Backup everything
kubectl exec -n velero deploy/velero -- velero backup create full-backup

# Backup with label selector
kubectl exec -n velero deploy/velero -- velero backup create app-backup \
  --selector app=my-app
```

### List Backups

```bash
kubectl exec -n velero deploy/velero -- velero backup get
```

### Describe a Backup

```bash
kubectl exec -n velero deploy/velero -- velero backup describe my-backup
```

### Restore from Backup

```bash
# Restore to same namespace
kubectl exec -n velero deploy/velero -- velero restore create \
  --from-backup my-backup

# Restore to different namespace
kubectl exec -n velero deploy/velero -- velero restore create \
  --from-backup my-backup \
  --namespace-mappings old-ns:new-ns
```

### Delete a Backup

```bash
kubectl exec -n velero deploy/velero -- velero backup delete my-backup
```

## Testing

Run the Velero test suite:

```bash
make velero-test
```

This will:
1. Verify Velero deployment is running
2. Check backup storage location is available
3. Create test resources in a test namespace
4. Create a backup of the test namespace
5. Delete the test namespace
6. Restore from backup
7. Verify resources were restored

## Troubleshooting

### Check Velero Logs

```bash
kubectl logs -n velero deployment/velero
```

### Check Backup Storage Location

```bash
kubectl get backupstoragelocation -n velero
kubectl describe backupstoragelocation default -n velero
```

### Verify Minio Connectivity

```bash
kubectl run velero-minio-test \
  --image=minio/mc:latest \
  --restart=Never \
  --rm -i \
  --namespace velero \
  --env="MC_HOST_myminio=http://minioadmin:minioadmin123@minio.minio.svc.cluster.local:9000" \
  -- mc ls myminio/velero/
```

### Backup Failed

1. Check Velero logs:
   ```bash
   kubectl logs -n velero deployment/velero --tail=50
   ```

2. Describe the backup:
   ```bash
   kubectl describe backup <backup-name> -n velero
   ```

3. Check backup storage location:
   ```bash
   kubectl get backupstoragelocation -n velero -o yaml
   ```

### Restore Failed

1. Check restore logs:
   ```bash
   kubectl exec -n velero deploy/velero -- velero restore logs <restore-name>
   ```

2. Describe the restore:
   ```bash
   kubectl describe restore <restore-name> -n velero
   ```

## Production Considerations

For production (k3s), consider:

- **Persistent Storage**: Use a production-grade S3 backend (AWS S3, MinIO cluster)
- **Encryption**: Enable backup encryption at rest
- **Retention**: Configure longer retention policies
- **Volume Snapshots**: Enable CSI snapshots if supported
- **Multiple Locations**: Configure multiple backup storage locations for redundancy
- **Monitoring**: Enable ServiceMonitor for Prometheus metrics

Example production values:

```yaml
configuration:
  backupStorageLocation:
    - name: primary
      provider: aws
      bucket: velero-backups
      config:
        region: us-west-2
        s3ForcePathStyle: "false"
    - name: secondary
      provider: aws
      bucket: velero-backups-dr
      config:
        region: us-east-1

  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: us-west-2
```

## Version

Velero Helm chart version: **7.2.1**

To upgrade, update the `CHART_VERSION` variable in `scripts/velero-up.sh`.

## References

- [Velero Documentation](https://velero.io/docs/)
- [Velero Helm Chart](https://github.com/vmware-tanzu/helm-charts/tree/main/charts/velero)
- [AWS Plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws)
- [Restic Integration](https://velero.io/docs/latest/restic/)
