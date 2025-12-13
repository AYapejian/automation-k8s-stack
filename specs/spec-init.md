**IMPORTANT: This file describes a lot of different points about what this project should support. It is up to Cloud Code to interpret all the info below, split it up into logical sections for development, and create a to-do list that will branch off of features for each logical section defined. Everything should use best practices, BG, GitHub Action, testable, run within a KIND cluster, and eventually deployable to self-hosted and cloud providers at a later date.**



Kubernetes deployable services that make up a home automation system.  


# System Requirements:

1. Should test everying in a kind cluster
2. Cluster must have a service mesh
3. Cluster must have full observability stack
4. Observability stack must support detailed metrics
5. Observability stack must support distributed tracing
6. Each set of services should be deployable as a logical unit using best practices for management.  ( Helm )
7. Should be deployable, testable, and updateable as a stacks
8. Automation setup should be resiliant
9. Must support running certain services on certain nodes due to hardware availability
10. Metrics must be collected from each deployed service 

# Services

## Home Automation

* *HomeAssistant
    * Bound to hardware based USB devices
* *MQTT Broker
* Zigbee to Mqtt
    * Bound to zigbee ddevice node
* Homekit Bridge

## Security 

* Frigate NVR
    * Bound to NAS Storage
    * Bound to NVidia device node

## Media Center

* All bound to shared NAS storeage
  * nzgbget
  * sonarr
  * radarr

## Observation

* Prometheus
* Grafana ( HomeAssistant and Cluster Metrics )
* Loki
* Jaegar ( Tracing )
* Influxdb ( For HomeAssistant )

# Supporting Services

* Minio
* Velero
* Ingress

# Development Style

## Repo dev setup

* GHA to build and test
* Kind cluster to test, debug, run locally 
* Deployable to a local k3s cluster that is self hosted
* **NO SECRETS EXPOSED**
* Sertup and teardown scripts

## Initial cluster and testing framework

* Create a todo list based on the above
* Each item should be on it's own branch 
* Start with cluster creation and testing harness
* Testing harness should allow running via github actions and test in the kind cluster ( Or whatever is best practice )
* Add cluster supporting services like isto mesh with best practice setup
* Add observability stack integrated with all services
* Ensure all Logging framework is setup with best practices and minimum overhead
* Debugability and observability are a high priority


## Cluster Access

* Ingress should be setup such that testing within kind cluster will be an identical test to when deployed into a production cluster. 
* Ingress should have rules routing services withing the cluster mesh and support full span tracing

## Setting up Home Automation

* Setup home automation stack
* Home Assistant is the main central priority
* Setup all other service dependencies 
* Ensure all metrics and logging is collected by observability stack

## Security 

* Setup Frigate NVR




