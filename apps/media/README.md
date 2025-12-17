# Media Stack

Media management components deployed with Istio service mesh integration.

## Components

| Component | Description | Port | Ingress URL |
|-----------|-------------|------|-------------|
| Heimdall | Application dashboard / start page | 80 | https://heimdall.localhost:8443 |
| nzbget | Usenet downloader | 6789 | https://nzbget.localhost:8443 |
| Sonarr | TV show management | 8989 | https://sonarr.localhost:8443 |
| Radarr | Movie management | 7878 | https://radarr.localhost:8443 |

## Architecture

```
+------------------+
|  Shared Storage  |
|  (downloads PVC) |
+--------+---------+
         |
         v
+--------+---------+
|     nzbget       |  <-- Downloads content
|   (port 6789)    |
+--------+---------+
         |
    +----+----+
    |         |
    v         v
+-------+  +-------+
| Sonarr|  | Radarr|  <-- Import and organize
| (8989)|  | (7878)|
+-------+  +-------+
    |         |
    v         v
  /tv       /movies   <-- Final media location
```

All components share the `media-downloads` PVC for file handoff.
In production (k3s), this would be NAS-backed storage.

## Deployment

```bash
# Deploy stack
make media-stack-up

# Check status
make media-stack-status

# Run tests
make media-stack-test

# Teardown
make media-stack-down
```

## k3d vs k3s Differences

| Feature | k3d (dev/CI) | k3s (production) |
|---------|--------------|------------------|
| Shared storage | local-path (ReadWriteMany) | NFS NAS storage |
| Media storage | emptyDir (temporary) | NFS NAS storage |
| Node affinity | Soft preferences | Hard requirements |

## Configuration

### Connecting Apps Together

1. **Configure nzbget as download client in Sonarr/Radarr:**
   - Host: `nzbget.media.svc.cluster.local`
   - Port: `6789`
   - Username: `nzbget`
   - Password: `tegbzn6789` (default, change in production)

2. **Set download paths:**
   - nzbget downloads to: `/downloads`
   - Sonarr/Radarr import from: `/downloads`
   - Sonarr organizes to: `/tv`
   - Radarr organizes to: `/movies`

### Default Credentials

| App | Username | Password |
|-----|----------|----------|
| nzbget | nzbget | tegbzn6789 |
| Sonarr | - | (no auth by default) |
| Radarr | - | (no auth by default) |

### Prometheus Metrics

Sonarr and Radarr have ServiceMonitors that scrape the `/ping` endpoint.
For full metrics, consider adding [Exportarr](https://github.com/onedr0p/exportarr) sidecars.

## Security Notes

- Default nzbget password should be changed in production via Sealed Secret
- Sonarr/Radarr should have authentication enabled in production
- All inter-service communication is secured via Istio mTLS

## Heimdall Dashboard

Heimdall serves as the central start page for all cluster services. Access it at:
https://heimdall.localhost:8443

### Configuring Heimdall

After deployment, add applications through the Heimdall UI:

1. Click "Items" in the bottom bar
2. Click "Add" button
3. Search for the application type (e.g., "Grafana", "Sonarr")
4. Enter the service URL
5. Click "Save"

### Cluster Services to Add

| Category | Service | URL | Enhanced App |
|----------|---------|-----|--------------|
| **Observability** | Grafana | https://grafana.localhost:8443 | Yes |
| | Prometheus | https://prometheus.localhost:8443 | No |
| | Jaeger | https://jaeger.localhost:8443 | No |
| **Home Automation** | Home Assistant | https://homeassistant.localhost:8443 | Yes |
| | Homebridge | https://homebridge.localhost:8443 | No |
| | Zigbee2MQTT | https://zigbee2mqtt.localhost:8443 | No |
| **Media** | Sonarr | https://sonarr.localhost:8443 | Yes |
| | Radarr | https://radarr.localhost:8443 | Yes |
| | NZBGet | https://nzbget.localhost:8443 | Yes |
| **Platform** | ArgoCD | https://argocd.localhost:8443 | No |
| | Minio | https://minio.localhost:8443 | No |

Enhanced apps can display live statistics when API keys are configured.
