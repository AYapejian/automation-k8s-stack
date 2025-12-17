# k3s Production Deployment Guide

This guide covers deploying the automation stack to a production k3s cluster with real hardware (NAS storage, USB devices, GPUs).

## Prerequisites

### Hardware Requirements
- **Server Node**: Control plane, runs ArgoCD and system services
- **Worker Nodes**: Run workloads with specific hardware
  - At least one node with USB access (for HomeAssistant Zigbee dongle)
  - At least one node with NAS access (for media storage)
  - Optional: Node with NVIDIA GPU (for Frigate)

### Software Requirements
```bash
# On all nodes
curl -sfL https://get.k3s.io | sh -

# On server node (first)
curl -sfL https://get.k3s.io | sh -s - server --cluster-init

# On agent nodes (get token from server: /var/lib/rancher/k3s/server/node-token)
curl -sfL https://get.k3s.io | K3S_URL=https://server:6443 K3S_TOKEN=xxx sh -
```

### Required Tools
- `kubectl` (installed with k3s)
- `helm` (v3.x)
- `kubeseal` (for Sealed Secrets)

## Step 1: Apply Node Labels

Apply labels to nodes based on their hardware capabilities. See [node-labels.md](./node-labels.md) for details.

```bash
# Example: Label a node with USB access
kubectl label nodes <node-name> hardware/usb=true

# Example: Label a node with NAS access
kubectl label nodes <node-name> storage/nas=true

# Example: Label a node with NVIDIA GPU
kubectl label nodes <node-name> hardware/nvidia=true
```

## Step 2: Install NFS CSI Driver

Required for NAS-backed storage:

```bash
# Add the Helm repo
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update

# Install the NFS CSI driver
helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system \
  --set externalSnapshotter.enabled=true \
  --values clusters/k3s/nfs-csi-values.yaml
```

## Step 3: Configure NAS Storage

Edit `platform/storage/k3s/nas-storageclass.yaml` with your NAS details:

```yaml
parameters:
  server: "nas.local"           # Your NAS hostname/IP
  share: "/volume1/kubernetes"  # NFS share path
```

Apply the StorageClass:
```bash
kubectl apply -f platform/storage/k3s/nas-storageclass.yaml
```

## Step 4: Create Production Sealed Secrets

Generate a new keypair for production (do NOT use the CI keypair):

```bash
# Generate a new keypair
openssl req -x509 -nodes -newkey rsa:4096 -keyout sealed-secrets.key \
  -out sealed-secrets.crt -days 3650 -subj "/CN=sealed-secret/O=sealed-secret"

# Create the secret in the cluster
kubectl -n kube-system create secret tls sealed-secrets-key \
  --cert=sealed-secrets.crt --key=sealed-secrets.key

# Label for the controller to use it
kubectl -n kube-system label secret sealed-secrets-key \
  sealedsecrets.bitnami.com/sealed-secrets-key=active
```

Keep `sealed-secrets.key` secure and backed up! You'll need it to seal new secrets.

## Step 5: Bootstrap ArgoCD

```bash
# Install ArgoCD
make argocd-up

# Apply the production-specific root application
kubectl apply -f clusters/k3s/argocd-root-app.yaml
```

## Step 6: Apply Production Overlays

The k3s overlays adjust resources, storage classes, and affinity rules for production.
Overlays are located in `clusters/k3s/overlays/`.

### Home Automation
```bash
kubectl apply -k clusters/k3s/overlays/home-automation/
```

### Media Stack
> Note: Media stack overlay will be added after the media stack PR merges.
```bash
kubectl apply -k clusters/k3s/overlays/media/
```

## Step 7: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -A

# Verify NAS storage is working
kubectl get pvc -A

# Check hardware affinity
kubectl get pods -o wide -n home-automation
kubectl get pods -o wide -n media
```

## Troubleshooting

### Pods stuck in Pending
Check node labels and taints:
```bash
kubectl describe node <node-name>
kubectl describe pod <pod-name> -n <namespace>
```

### NFS mount failures
Verify NFS connectivity from nodes:
```bash
# On worker node
showmount -e nas.local
mount -t nfs nas.local:/volume1/kubernetes /mnt
```

### USB device not accessible
Ensure the device is passed through and permissions are correct:
```bash
# On the node with USB
ls -la /dev/serial/by-id/
```

## Backup & Restore

Velero is configured to back up to Minio. For production, consider:
1. Using an external S3-compatible storage (AWS S3, MinIO on NAS)
2. Configuring backup schedules for critical namespaces
3. Testing restore procedures regularly

## Architecture Differences from k3d

| Component | k3d (Dev) | k3s (Production) |
|-----------|-----------|------------------|
| Storage | local-path | NFS NAS |
| USB devices | Mocked | Real passthrough |
| GPU | N/A | NVIDIA device plugin |
| Ingress | localhost:8443 | Real domain + Let's Encrypt |
| Node count | 1 server + 2 agents | Scalable |
| Sealed Secrets | CI keypair | Production keypair |
