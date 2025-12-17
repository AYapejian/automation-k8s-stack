# Media Stack

Media management components deployed with Istio service mesh integration.

## Components

| Component | Description | Port | Ingress URL |
|-----------|-------------|------|-------------|
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
