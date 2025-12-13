# Storage Configuration

This directory contains storage class definitions and documentation for the automation-k8s-stack.

## Overview

The storage layer provides persistent volume provisioning for applications that need durable storage.

### k3d (Development/CI)

k3d clusters use the built-in **local-path-provisioner** provided by k3s. This is automatically available with no additional installation.

**Default StorageClass:**
```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

Key characteristics:
- **Provisioner**: `rancher.io/local-path` - Creates directories on the node
- **ReclaimPolicy**: `Delete` - PV is deleted when PVC is deleted
- **VolumeBindingMode**: `WaitForFirstConsumer` - PV created only when pod scheduled

### k3s (Production)

Production clusters use NFS storage backed by a NAS device. The `nas` StorageClass is defined in `k3s/nas-storageclass.yaml`.

**Note**: The NAS StorageClass is a placeholder. The actual NFS CSI driver configuration happens in Phase 6.2 (k3s Deployment Overlays).

## StorageClasses

| Name | Environment | Provisioner | Use Case |
|------|-------------|-------------|----------|
| `local-path` | k3d | rancher.io/local-path | General workloads, development (default) |
| `nas` | k3s | nfs.csi.k8s.io | Production data, shared storage |

## Usage

### Creating a PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
  namespace: my-namespace
spec:
  accessModes:
    - ReadWriteOnce
  # storageClassName: local-path  # Optional - uses default if omitted
  # storageClassName: nas         # Use for k3s production (NFS)
  resources:
    requests:
      storage: 1Gi
```

### Access Modes

| Mode | Description | local-path | NAS |
|------|-------------|------------|-----|
| `ReadWriteOnce` | Single node read/write | Yes | Yes |
| `ReadOnlyMany` | Multiple nodes read | No | Yes |
| `ReadWriteMany` | Multiple nodes read/write | No | Yes |

### PVC Templates by Application Type

**Database (single-writer):**
```yaml
accessModes: [ReadWriteOnce]
storageClassName: standard
storage: 10Gi
```

**Shared media storage (multi-reader):**
```yaml
accessModes: [ReadWriteMany]
storageClassName: nas  # k3s only
storage: 100Gi
```

## Testing

```bash
# Run storage provisioning test
make storage-test

# Check StorageClasses
kubectl get storageclass

# Check PVCs
kubectl get pvc --all-namespaces
```

## Files

```
platform/storage/
├── README.md                    # This file
└── k3s/
    └── nas-storageclass.yaml    # NFS StorageClass for k3s production
```

## Troubleshooting

### PVC Stuck in Pending

1. Check StorageClass exists:
   ```bash
   kubectl get storageclass
   ```

2. Check provisioner logs (k3d):
   ```bash
   kubectl logs -n kube-system -l app=local-path-provisioner
   ```

3. PVC with `WaitForFirstConsumer` stays Pending until a pod references it - this is expected behavior.

### Volume Not Mounting

1. Verify PVC is Bound:
   ```bash
   kubectl get pvc -n <namespace>
   ```

2. Check pod events:
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   ```

3. Verify access mode matches pod requirements.
