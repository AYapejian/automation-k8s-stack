# Minio Object Storage

Minio provides S3-compatible object storage for the automation stack. It's used by:
- **Loki** - Log chunk storage
- **Tempo** - Trace storage
- **Velero** - Backup storage

## Quick Start

```bash
# Install
make minio-up

# Check status
make minio-status

# Uninstall
make minio-down
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Minio (Standalone)                   │
├─────────────────────────────────────────────────────────┤
│  Buckets:                                               │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ │
│  │ loki-chunks   │ │ tempo-traces  │ │ velero        │ │
│  └───────────────┘ └───────────────┘ └───────────────┘ │
├─────────────────────────────────────────────────────────┤
│  API: 9000  │  Console: 9001                            │
└─────────────────────────────────────────────────────────┘
```

## Endpoints

| Service | Internal URL | External URL |
|---------|--------------|--------------|
| API | `http://minio.minio.svc.cluster.local:9000` | N/A |
| Console | `http://minio-console.minio.svc.cluster.local:9001` | `https://minio.localhost:8443` |

## Credentials

For k3d development, default credentials are:
- **Username**: `minioadmin`
- **Password**: `minioadmin123`

> **Note**: For production, use Sealed Secrets to encrypt credentials.

## Buckets

| Bucket | Purpose | Consumer |
|--------|---------|----------|
| `loki-chunks` | Log storage | Loki |
| `tempo-traces` | Trace storage | Tempo |
| `velero` | Backup storage | Velero |

Buckets are created automatically by the Helm chart's `makeBucketJob`.

## Configuration

### k3d (Development)

- Mode: Standalone (single replica)
- Storage: 10Gi PVC with local-path provisioner
- Resources: 256Mi memory request, 512Mi limit

### k3s (Production)

For production, consider:
- Mode: Distributed (4+ replicas)
- Storage: NAS-backed StorageClass
- TLS enabled
- Resource increases
- Proper Sealed Secrets for credentials

## Connecting Applications

### From Loki

```yaml
# In Loki values.yaml
storage:
  type: s3
  s3:
    endpoint: http://minio.minio.svc.cluster.local:9000
    bucketnames: loki-chunks
    access_key_id: ${MINIO_ACCESS_KEY}
    secret_access_key: ${MINIO_SECRET_KEY}
    s3forcepathstyle: true
```

### From Tempo

```yaml
# In Tempo values.yaml
storage:
  trace:
    backend: s3
    s3:
      bucket: tempo-traces
      endpoint: minio.minio.svc.cluster.local:9000
      access_key: ${MINIO_ACCESS_KEY}
      secret_key: ${MINIO_SECRET_KEY}
      insecure: true
```

### From Velero

```yaml
# In Velero values.yaml
configuration:
  backupStorageLocation:
    bucket: velero
    config:
      s3Url: http://minio.minio.svc.cluster.local:9000
      region: us-east-1
      s3ForcePathStyle: true
```

## Using mc CLI

To interact with Minio from a pod:

```bash
# Port-forward for local access
kubectl port-forward -n minio svc/minio 9000:9000

# Configure mc
mc alias set myminio http://localhost:9000 minioadmin minioadmin123

# List buckets
mc ls myminio

# Upload a file
mc cp myfile.txt myminio/loki-chunks/
```

## Troubleshooting

### Pod not starting

```bash
# Check pod status
kubectl get pods -n minio

# Check pod events
kubectl describe pod -n minio -l app.kubernetes.io/name=minio

# Check PVC
kubectl get pvc -n minio
```

### Bucket creation failed

```bash
# Check the make-bucket job
kubectl get jobs -n minio
kubectl logs job/minio-make-bucket -n minio
```

### Connection refused

1. Verify the service is running:
   ```bash
   kubectl get svc -n minio
   ```

2. Check endpoints:
   ```bash
   kubectl get endpoints -n minio
   ```

3. Test connectivity from another pod:
   ```bash
   kubectl run -it --rm curl --image=curlimages/curl -- \
     curl -v http://minio.minio.svc.cluster.local:9000/minio/health/live
   ```
