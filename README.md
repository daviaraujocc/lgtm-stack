# 🔍 LGTM Stack for Kubernetes

<br>

<div align="center">
    <a href="README.md">🇺🇸 English</a> | <a href="README.pt-br.md">🇧🇷 Português (Brasil)</a>
</div>
<br>

A complete observability platform deployment guide for Kubernetes. The LGTM stack, by Grafana Labs, combines best-in-class open-source tools to provide comprehensive system visibility, consisting of:

- **Loki**: Log storage and management
- **Tempo**: Distributed tracing storage and management
- **Mimir**: Long-term metrics storage
- **Grafana**: Interface & Dashboards

## Architecture

The LGTM stack architecture integrates all components to provide a complete observability solution:

![LGTM Architecture](./assets/images/lgtm.jpg)

Each component (Loki, Grafana, Tempo, Mimir) runs in Kubernetes with its own storage backend. For instance we are using GCP Cloud Storage as example, but they support AWS/Azure as backends too, for local development we can use MinIO.

Also the stack includes three optional components:
- Prometheus: collects cluster metrics (CPU/Memory) and sends to Mimir
- Promtail: agent that captures container logs and sends to Loki
- OpenTelemetry Collector: routes all telemetry data to appropriate backends, acts as a central hub

## Quick Start 

### ✨ Prerequisites
- Helm v3+ (package manager)
- kubectl 
- For GCP: gcloud CLI with project owner permissions

### Hardware Requirements

Local development:
- 2-4 CPUs
- 8 GB RAM
- 50 GB disk space

Production setup:
- Can vary a lot depending on the amount of data and traffic, it's recommended to start with a small setup and scale as needed, for small setups with 20 million logs consumed per day, 11k metrics per minute and 3 million spans per day, the following setup is recommended:
  - 8 CPUs
  - 24 GB RAM
  - 100 GB disk space (SSD, don't count for storage backends)

### Setup
```bash
# Add repositories & create namespace
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create ns monitoring
```

### Choose Your Environment

#### Local Development (k3s, minikube)

For local testing and development scenarios. Uses local storage via MinIO.

```bash
helm install lgtm --version 2.1.0 -n monitoring \
  grafana/lgtm-distributed -f helm/values-lgtm.local.yaml
```

#### GCP Production Setup

For production environments, using GCP resources for storage and monitoring.

1. Set up GCP resources:

```bash
# Set your project ID
export PROJECT_ID=your-project-id

# Create buckets with random suffix
export BUCKET_SUFFIX=$(openssl rand -hex 4 | tr -d "\n")
for bucket in logs traces metrics metrics-admin; do
  gsutil mb -p ${PROJECT_ID} -c standard -l us-east1 gs://lgtm-${bucket}-${BUCKET_SUFFIX}
done

# Update bucket names in config
sed -i -E "s/(bucket_name:\s*lgtm-[^[:space:]]+)/\1-${BUCKET_SUFFIX}/g" helm/values-lgtm.gcp.yaml

# Create and configure service account
gcloud iam service-accounts create lgtm-monitoring \
    --display-name "LGTM Monitoring" \
    --project ${PROJECT_ID}

# Set permissions
for bucket in logs traces metrics metrics-admin; do 
  gsutil iam ch serviceAccount:lgtm-monitoring@${PROJECT_ID}.iam.gserviceaccount.com:admin \
    gs://lgtm-${bucket}-${BUCKET_SUFFIX}
done

# Create service account key and secret
gcloud iam service-accounts keys create key.json \
    --iam-account lgtm-monitoring@${PROJECT_ID}.iam.gserviceaccount.com
kubectl create secret generic lgtm-sa --from-file=key.json -n monitoring
```

2. Install LGTM stack:

Change values-lgtm.gcp.yaml according to your needs before applying, like ingress configuration, resources requests, etc.

```bash
helm install lgtm --version 2.1.0 -n monitoring \
  grafana/lgtm-distributed -f helm/values-lgtm.gcp.yaml
```

## Install dependencies 


```bash
# Install Promtail for collecting container logs
# Check if you are using Docker or CRI-O runtime
## Docker runtime
kubectl apply -f manifests/promtail.docker.yaml
## CRI-O runtime
kubectl apply -f manifests/promtail.cri.yaml

# Install prometheus operator for metrics collection
helm install prometheus-operator --version 66.3.1 -n monitoring \
  prometheus-community/kube-prometheus-stack -f helm/values-prometheus.yaml

# Install kubernetes dashboards for grafana
kubectl apply -f manifests/kubernetes-dashboards.yaml
```


## Testing

### Access Grafana
```bash
# Access dashboard
kubectl port-forward svc/lgtm-grafana 3000:80 -n monitoring

# Get password credentials
kubectl get secret --namespace monitoring lgtm-grafana -o jsonpath="{.data.admin-password}" | base64 --decode
```
- Default username: `admin`
- Access URL: http://localhost:3000
- Check default Grafana dashboards and Explore tab

### Component Testing

After installation, verify each component is working correctly:

#### Loki (Logs)
Test log ingestion and querying:

```bash
# Forward Loki port
kubectl port-forward svc/lgtm-loki-distributor 3100:3100 -n monitoring

# Send test log with timestamp and labels
curl -XPOST http://localhost:3100/loki/api/v1/push -H "Content-Type: application/json" -d '{
  "streams": [{
    "stream": { "app": "test", "level": "info" },
    "values": [[ "'$(date +%s)000000000'", "Test log message" ]]
  }]
}'
```

To verify:
1. Open Grafana (http://localhost:3000)
2. Go to Explore > Select Loki datasource
3. Query using labels: `{app="test", level="info"}`
4. You should see your test message in the results


If you have installed promtail you can check the container logs also on Explore tab.

#### Tempo (Traces)

```bash
# Forward Tempo port
kubectl port-forward svc/lgtm-tempo-distributor 4318:4318 -n monitoring

# Generate sample traces with service name 'test'
docker run --add-host=host.docker.internal:host-gateway --env=OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318 jaegertracing/jaeger-tracegen -service test -traces 10
```

To verify:
1. Go to Explore > Select Tempo datasource
2. Search by Service Name: 'test'
3. You should see 10 traces with different spans

#### Mimir (Metrics)

If Prometheus operator was installed, we have an instance running inside the cluster sending basic metrics (CPU/Memory) to mimir, you can check the metrics already in Grafana:

1. Access Grafana
2. Go to Explore > Select Mimir datasource
3. Try these example queries:
   - `rate(container_cpu_usage_seconds_total[5m])` - CPU usage
   - `container_memory_usage_bytes` - Container memory usage

### Troubleshooting Tips

If components aren't working:

1. Check pod status:
```bash
kubectl get pods -n monitoring
```

2. View component logs:
```bash
# For Loki
kubectl logs -l app.kubernetes.io/name=loki -n monitoring

# For Tempo
kubectl logs -l app.kubernetes.io/name=tempo -n monitoring

# For Mimir
kubectl logs -l app.kubernetes.io/name=mimir -n monitoring
```

> Check official documentation for each component for more troubleshooting steps.

## Additional Components

### OpenTelemetry Collector

The OpenTelemetry Collector acts as a central hub for all telemetry data:

```bash
# Install OpenTelemetry Collector
kubectl apply -f manifests/otel-collector.yaml
```

#### Endpoints Configuration

| Data Type | Protocol | Endpoint | Port |
|-----------|----------|----------|------|
| Traces | gRPC | otel-collector | 4317 |
| Traces | HTTP | otel-collector | 4318 |
| Metrics | gRPC | otel-collector | 4317 |
| Metrics | HTTP | otel-collector | 4318 |
| Logs | HTTP | otel-collector | 3100 |

#### Integration with Components

1. **Promtail Configuration**
   - Edit `manifests/promtail.yaml`
   - Update clients section:
   ```yaml
   clients:
     - url: http://otel-collector:3100/loki/api/v1/push
   ```

2. **Application Integration**
   - Use OpenTelemetry SDKs
   - Configure endpoint: `otel-collector:4317` for gRPC
   - For HTTP: `http://otel-collector:4318`

#### Verification

Check collector is receiving data:
```bash
# View collector logs
kubectl logs -l app=otel-collector -n monitoring
```

#### Extra Configuration

##### Loki Labels Customization

To add new labels to logs in Loki through the OpenTelemetry Collector:

1. Edit the ConfigMap `otel-collector-config`
2. Locate the `processors.attributes/loki` section
3. Add your custom labels to the `loki.attribute.labels` list:

```yaml
processors:
  attributes/loki:
    actions:
      - action: insert
        key: loki.format
        value: raw
      - action: insert
        key: loki.attribute.labels
        value: facility, level, source, host, app, namespace, pod, container, job, your_label
```

> After modifying the ConfigMap, restart the collector pod to apply the changes:
> ```bash
> kubectl rollout restart daemonset/otel-collector -n monitoring
> ```

## Uninstall

```bash
# Remove LGTM stack
helm uninstall lgtm -n monitoring

# Remove prometheus operator 
helm uninstall prometheus-operator -n monitoring

# Remove namespace
kubectl delete ns monitoring

# Remove promtail & otel-collector 
kubectl delete -f manifests/promtail.yaml
kubectl delete -f manifests/otel-collector.yaml

# For GCP setup, cleanup:
for bucket in logs traces metrics metrics-admin; do
  gsutil rm -r gs://lgtm-${bucket}-${BUCKET_SUFFIX}
done

gcloud iam service-accounts delete lgtm-monitoring@${PROJECT_ID}.iam.gserviceaccount.com
```