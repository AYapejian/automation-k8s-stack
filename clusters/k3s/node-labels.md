# Node Labels for Hardware Affinity

This document describes the node labels used for hardware affinity scheduling in k3s production.

## Required Labels

Apply these labels to nodes based on their hardware capabilities:

### USB Device Access
```bash
# For nodes with USB devices (Zigbee dongles, Z-Wave, etc.)
kubectl label nodes <node-name> hardware/usb=true
kubectl label nodes <node-name> hardware/zigbee=true  # If Zigbee dongle present
```

**Used by:**
- HomeAssistant (optional USB passthrough)
- Zigbee2MQTT (required for real Zigbee coordinator)

### NAS Storage Access
```bash
# For nodes that should mount NAS storage
kubectl label nodes <node-name> storage/nas=true
```

**Used by:**
- Media stack (nzbget, Sonarr, Radarr)
- Frigate (recording storage)
- Any workload needing persistent media storage

### NVIDIA GPU Access
```bash
# For nodes with NVIDIA GPUs
kubectl label nodes <node-name> hardware/nvidia=true
```

**Used by:**
- Frigate (object detection)

**Requires:**
- NVIDIA Container Toolkit installed on node
- NVIDIA device plugin deployed in cluster

## Example Node Setup

### Typical Home Server Layout

```
┌─────────────────────────────────────────────────────────┐
│ Node: server-1 (Control Plane)                          │
│ Labels: (none required)                                 │
│ Runs: ArgoCD, Prometheus, system services               │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Node: worker-1                                          │
│ Labels: hardware/usb=true, hardware/zigbee=true         │
│ Hardware: Zigbee USB dongle                             │
│ Runs: HomeAssistant, Zigbee2MQTT                        │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Node: worker-2                                          │
│ Labels: storage/nas=true, hardware/nvidia=true          │
│ Hardware: NAS mount, NVIDIA GPU                         │
│ Runs: Media stack, Frigate                              │
└─────────────────────────────────────────────────────────┘
```

## Applying Labels

### Via kubectl
```bash
# Apply a label
kubectl label nodes worker-1 hardware/usb=true

# Remove a label
kubectl label nodes worker-1 hardware/usb-

# View labels
kubectl get nodes --show-labels
```

### Via k3s agent installation
```bash
# Include labels when joining the cluster
curl -sfL https://get.k3s.io | K3S_URL=https://server:6443 K3S_TOKEN=xxx \
  sh -s - --node-label hardware/usb=true --node-label hardware/zigbee=true
```

## Affinity Configurations

### Hard Affinity (Required)
Pods will NOT schedule without matching labels:

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: hardware/zigbee
                operator: In
                values: ["true"]
```

### Soft Affinity (Preferred)
Pods prefer nodes with labels but will schedule elsewhere if needed:

```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: storage/nas
                operator: In
                values: ["true"]
```

## Workload Label Requirements

| Workload | Required Labels | Preferred Labels |
|----------|-----------------|------------------|
| HomeAssistant | - | hardware/usb |
| Zigbee2MQTT | hardware/zigbee | - |
| Homebridge | - | - |
| nzbget | - | storage/nas |
| Sonarr | - | storage/nas |
| Radarr | - | storage/nas |
| Frigate | hardware/nvidia | storage/nas |
