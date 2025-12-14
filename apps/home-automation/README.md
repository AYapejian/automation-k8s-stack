# Home Automation Stack

Home automation components deployed with Istio service mesh integration.

## Components

| Component | Description | Port | Ingress URL |
|-----------|-------------|------|-------------|
| Mosquitto | MQTT broker | 1883 | - (internal only) |
| HomeAssistant | Core automation platform | 8123 | https://homeassistant.localhost:8443 |
| Zigbee2MQTT | Zigbee device bridge | 8080 | https://zigbee2mqtt.localhost:8443 |
| Homebridge | Apple HomeKit bridge | 8581 | https://homebridge.localhost:8443 |

## Architecture

```
                     +-------------------+
                     |  Mosquitto MQTT   |
                     |  (port 1883)      |
                     +--------+----------+
                              |
         +--------------------+--------------------+
         |                    |                    |
         v                    v                    v
+----------------+   +----------------+   +----------------+
| HomeAssistant  |   |  Zigbee2MQTT   |   |   Homebridge   |
| (port 8123)    |   |  (port 8080)   |   |   (port 8581)  |
+----------------+   +----------------+   +----------------+
```

All components communicate via MQTT. Istio provides mTLS between services.

## Deployment

```bash
# Deploy stack
make home-automation-up

# Check status
make home-automation-status

# Run tests
make home-automation-test

# Teardown
make home-automation-down
```

## k3d vs k3s Differences

| Feature | k3d (dev/CI) | k3s (production) |
|---------|--------------|------------------|
| Zigbee hardware | Mocked (adapter: null) | Real USB device |
| Node affinity | Soft preferences | Hard requirements |
| USB passthrough | N/A | hostPath volumes |

## Configuration

### MQTT Connection
All components connect to Mosquitto at:
```
mqtt://mosquitto.home-automation.svc.cluster.local:1883
```

### Prometheus Metrics
HomeAssistant exposes metrics at `/api/prometheus` which are scraped by Prometheus via ServiceMonitor.
