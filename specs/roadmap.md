# Project Roadmap

Each phase represents a logical unit of work. Each numbered item should be implemented on its own feature branch and merged via PR with passing CI.

## Decisions Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Local K8s | k3d | k3s in Docker - fast, cross-platform, reliable multi-node, matches prod |
| Service Mesh | Istio | Work experience requirement |
| Tracing | Jaeger + Tempo | Both for experience; OTel Collector fans out to both |
| Time-series DB | Prometheus only | Drop InfluxDB; HA Prometheus integration covers metrics |
| GitOps | ArgoCD | Feature-rich, good UI, widely adopted |
| Secrets | Sealed Secrets | Simple, git-native, testable offline, easy to migrate |
| CI Workflows | Tiered (fast PR + extended) | 88% faster PR feedback; full tests on merge/nightly |
| ArgoCD Timing | Implemented early (after Phase 5) | GitOps from start; all components managed declaratively |

---

## Phase 1: Foundation

**Goal**: Reproducible CI environment with k3d cluster and test harness.

### 1.1 Repository Structure + CI Skeleton
**Branch**: `feature/repo-structure`

- Directory structure:
  ```
  /
  ├── .github/workflows/       # GHA workflows
  ├── clusters/
  │   ├── k3d/                 # k3d cluster configs (local dev & CI)
  │   └── k3s/                 # k3s overlays (production)
  ├── platform/                # Service mesh, ingress, certs
  ├── observability/           # Prometheus, Grafana, Loki, tracing
  ├── apps/
  │   ├── home-automation/
  │   ├── media/
  │   └── security/
  ├── scripts/                 # Setup/teardown scripts
  └── tests/                   # Test definitions
  ```
- Base GHA workflow that runs on PR
- Makefile with common targets

**Acceptance Criteria**:
- [x] `make help` shows available targets
- [x] GHA workflow triggers on PR, runs placeholder test

### 1.2 k3d Cluster Creation
**Branch**: `feature/1.2-k3d-cluster`

- k3d config with:
  - Multi-node setup (1 server, 2 agents) for affinity testing
  - Port mappings for ingress (8080 -> 80, 8443 -> 443)
  - Built-in local registry (registry.localhost:5111)
  - Node labels for simulated hardware affinity
- Idempotent create/delete scripts

**Acceptance Criteria**:
- [ ] `make cluster-up` creates cluster (idempotent)
- [ ] `make cluster-down` destroys cluster (idempotent)
- [ ] GHA can spin up cluster in CI
- [ ] Running `make cluster-up` twice doesn't error
- [ ] Node labels applied for affinity testing

### 1.3 Test Harness Framework
**Branch**: `feature/test-harness`

- Choose test framework: **Chainsaw** (Kyverno's K8s test tool) or **bats** + kubectl
- Test patterns:
  - Resource exists and ready
  - Endpoints respond
  - Logs contain expected output
- Integration with GHA

**Acceptance Criteria**:
- [ ] Sample test validates cluster is running
- [ ] `make test` runs all tests
- [ ] Tests run in GHA after cluster creation

### 1.4 Sealed Secrets Setup
**Branch**: `feature/sealed-secrets`

- Deploy Sealed Secrets controller
- Generate test keypair for CI (deterministic, not production)
- Script to seal secrets offline
- Document migration path to External Secrets Operator

**Acceptance Criteria**:
- [ ] Controller deploys in cluster
- [ ] Can seal/unseal secrets in CI without interaction
- [ ] Test validates a sealed secret decrypts correctly

### 1.5 CI Optimization
**Branch**: `feature/ci-optimization`

- Split CI into tiered workflows for faster PR feedback
- Created two workflow architecture:
  - `pr-validation.yaml` - Fast PR checks (~3 min)
  - `extended-integration.yaml` - Full stack tests (~6 min)
- Path-based triggers for observability PRs
- Nightly scheduled runs for drift detection

**Acceptance Criteria**:
- [x] PR validation completes in under 6 minutes
- [x] Extended integration runs on merge to main
- [x] Observability PRs trigger full integration tests
- [x] Nightly schedule configured (6 AM UTC)

---

## Phase 2: Platform Layer

**Goal**: Service mesh, ingress, and certificates operational.

### 2.1 Istio Service Mesh
**Branch**: `feature/istio`

- Install via `istioctl` or Helm (prefer Helm for GitOps)
- Configuration:
  - Sidecar injection for labeled namespaces
  - mTLS strict mode
  - Telemetry to Prometheus (metrics), Jaeger/Tempo (traces)
- Base `PeerAuthentication` and `AuthorizationPolicy`

**Acceptance Criteria**:
- [ ] Istio control plane healthy
- [ ] Test workload gets sidecar injected
- [ ] mTLS verified between test pods
- [ ] Istio metrics appear in Prometheus (once deployed)

### 2.2 Ingress + Certificates
**Branch**: `feature/ingress`

- Istio Ingress Gateway (not separate NGINX - leverage mesh)
- cert-manager for TLS
- Self-signed ClusterIssuer for k3d
- Gateway + VirtualService patterns established

**Acceptance Criteria**:
- [ ] Ingress Gateway accessible on localhost:8080/8443
- [ ] cert-manager issues self-signed cert
- [ ] Sample app reachable via ingress with TLS

### 2.3 Storage Provisioner
**Branch**: `feature/storage`

- Local path provisioner for k3d (dynamic PV creation)
- StorageClass definitions:
  - `standard` - local-path (default)
  - `nas` - placeholder, overridden in k3s
- PVC templates for apps

**Acceptance Criteria**:
- [x] PVC dynamically provisions PV
- [x] Pod can mount and write to PVC

---

## Phase 3: Observability

**Goal**: Full metrics, logs, and traces before deploying apps.

### 3.1 Prometheus + Grafana Core
**Branch**: `feature/prometheus-grafana`

- kube-prometheus-stack Helm chart (includes Prometheus, Grafana, node-exporter, kube-state-metrics)
- ServiceMonitor for Istio
- Grafana datasource auto-provisioning

**Acceptance Criteria**:
- [ ] Prometheus scraping cluster metrics
- [ ] Grafana accessible via ingress
- [ ] Istio metrics visible in Grafana

### 3.2 Loki for Logs
**Branch**: `feature/loki`

- Loki + Promtail (or Grafana Alloy)
- Ship logs from all pods
- Grafana datasource for Loki

**Acceptance Criteria**:
- [ ] Logs from test pod queryable in Grafana
- [ ] Istio proxy logs captured

### 3.3 Tracing (Jaeger + Tempo)
**Branch**: `feature/tracing`

- OpenTelemetry Collector as trace receiver
- Fan out to:
  - Jaeger (for Jaeger UI experience)
  - Tempo (for Grafana-native querying)
- Istio configured to send traces to OTel Collector
- Grafana datasources for both

**Acceptance Criteria**:
- [ ] Traces appear in Jaeger UI
- [ ] Traces queryable in Grafana via Tempo
- [ ] End-to-end trace across Istio-meshed services

### 3.4 Dashboards + Alerts Baseline
**Branch**: `feature/dashboards`

- Grafana dashboards:
  - Cluster overview
  - Istio mesh
  - Per-namespace resource usage
- Basic PrometheusRules:
  - Pod crash looping
  - High error rate
  - PVC nearly full

**Acceptance Criteria**:
- [ ] Dashboards load without errors
- [ ] Alert fires for synthetic failure

---

## Phase 4: Backup & Storage Infrastructure

**Goal**: Object storage and backup automation.

### 4.1 Minio
**Branch**: `feature/minio`

- Single-node Minio for k3d (HA for prod)
- Buckets: `velero`, `tempo-traces`, `loki-chunks`
- Sealed Secret for credentials

**Acceptance Criteria**:
- [ ] Minio accessible in cluster
- [ ] Can create bucket via mc CLI
- [ ] Tempo/Loki can write to Minio (if configured)

### 4.2 Velero Backups
**Branch**: `feature/velero`

- Velero with Minio backend
- Backup schedule for namespaces
- Restore test

**Acceptance Criteria**:
- [ ] Velero backup completes
- [ ] Restore to new namespace succeeds

---

## Phase 5: Application Stacks

**Goal**: Deploy actual workloads. Each stack is independent.

### 5.1 Home Automation Stack
**Branch**: `feature/home-automation`

Components:
- HomeAssistant (with Prometheus integration)
- Mosquitto MQTT broker
- Zigbee2MQTT (mock in k3d, real hardware in k3s)
- Homebridge

**Validation needed**: Confirm HA Prometheus integration captures state changes and events adequately. If not, implement custom sensors or event-to-metric bridge.

Node Affinity:
- k3d: soft affinity to specific agents (simulated labels)
- k3s: hard affinity to nodes with USB/Zigbee hardware

**Acceptance Criteria**:
- [ ] All pods running and healthy
- [ ] HA metrics in Prometheus
- [ ] HA accessible via ingress
- [ ] MQTT communication works between HA and Zigbee2MQTT

### 5.2 Media Stack
**Branch**: `feature/5.2-media-stack`

Components:
- nzbget
- Sonarr
- Radarr

Shared storage via PVC (NAS in prod).

**Acceptance Criteria**:
- [x] All services accessible via ingress
- [x] Services can communicate with each other (shared downloads PVC)
- [x] Metrics exported to Prometheus (ServiceMonitors)

### 5.3 Security Stack (Frigate)
**Branch**: `feature/frigate`

Components:
- Frigate NVR

Hardware requirements (k3s only):
- NVIDIA GPU for detection
- NAS storage for recordings

k3d: Deploy with CPU-only config, no actual camera streams.

**Acceptance Criteria**:
- [ ] Frigate pod runs in k3d (degraded mode)
- [ ] Metrics exported
- [ ] GPU scheduling works in k3s (future)

---

## Phase 6: Production Readiness

**Goal**: GitOps and real hardware deployment.

### 6.1 ArgoCD Setup ✅ (Implemented Early)
**Branch**: `feature/argocd-*` (multiple PRs)

> **Note**: ArgoCD was implemented after Phase 5.1 to enable GitOps management from the start.
> All platform, observability, and workload components are now managed via ArgoCD Applications.

Implementation:
- ArgoCD bootstrap with k3d-optimized configuration
- App-of-apps pattern with root application
- Sync waves for dependency ordering (0-20)
- AppProjects: platform, observability, workloads
- Multi-source Applications for Helm + Git values
- VirtualService for ArgoCD UI access

**Acceptance Criteria**:
- [x] ArgoCD syncs from this repo
- [x] Changes to repo auto-deploy to cluster (auto-sync enabled)
- [x] Health status visible in ArgoCD UI
- [x] `make stack-up` deploys full stack via ArgoCD
- [x] CI validates ArgoCD-based deployment

### 6.2 k3s Deployment Overlays
**Branch**: `feature/k3s-overlays`

- Kustomize overlays for k3s environment
- Real NAS StorageClass
- Production Sealed Secrets keypair
- Node labels for hardware affinity

**Acceptance Criteria**:
- [ ] Manifests render correctly for k3s
- [ ] Documented deployment process

### 6.3 Hardware Affinity Configurations
**Branch**: `feature/hardware-affinity`

- Node labels:
  - `hardware/usb=true`
  - `hardware/zigbee=true`
  - `hardware/nvidia=true`
  - `storage/nas=true`
- Affinity rules in app deployments
- NVIDIA device plugin (k3s only)

**Acceptance Criteria**:
- [ ] Pods schedule to correct nodes in k3s
- [ ] USB device accessible in HomeAssistant pod
- [ ] GPU accessible in Frigate pod

---

## Branch Naming Convention

```
feature/<phase>-<component>
```

Examples:
- `feature/1.2-k3d-cluster`
- `feature/2.1-istio`
- `feature/5.1-home-automation`

## PR Workflow

1. Create feature branch from `main`
2. Implement with tests
3. PR triggers GHA → k3d cluster → ArgoCD sync → tests
4. Merge to `main` after review
5. ArgoCD auto-syncs changes to clusters (GitOps enabled)

---

## Open Questions / Future Considerations

- [ ] Multi-cluster with Istio (home + cloud)?
- [ ] External DNS for real domain resolution?
- [ ] SSO for all UIs (Grafana, ArgoCD, HA)?
- [ ] Disaster recovery testing schedule?
