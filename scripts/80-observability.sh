#!/usr/bin/env bash
# ============================================================================
# 80-observability.sh — prod-grade observability for the lab:
#
#   1. expose control-plane metrics on the cluster net (etcd :2381,
#      scheduler :10259, controller-manager :10257) — serial, health-checked
#   2. kube-prometheus-stack  (Prometheus Operator, Alertmanager, Grafana)
#   3. Cilium metrics + ServiceMonitors (agent, operator, Hubble, Envoy)
#   4. Loki (logs) + Alloy (collector)
#   5. Tempo (traces) + OpenTelemetry Collector (OTLP front door)
#   6. Gateway routes: grafana. / prometheus. / alertmanager.k8s.lab
#   7. wire podinfo tracing; verification battery
#
# Idempotent — re-run safely. Grafana admin password: .state/grafana-admin.pass
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

NS=observability

# ---------------------------------------------------- 1. control-plane metrics
# kubeadm binds these to 127.0.0.1 — fine until you want prod monitoring.
# Re-bind serially (each edit restarts that static pod via kubelet).
expose_cp_metrics() {
  local n changed
  for n in $CP_NODES; do
    changed=0
    if nssh "$n" "sudo grep -q 'listen-metrics-urls=http://127.0.0.1:2381' /etc/kubernetes/manifests/etcd.yaml"; then
      nssh "$n" "sudo sed -i 's#--listen-metrics-urls=http://127.0.0.1:2381#--listen-metrics-urls=http://0.0.0.0:2381#' /etc/kubernetes/manifests/etcd.yaml"
      changed=1
    fi
    if nssh "$n" "sudo grep -q -- '--bind-address=127.0.0.1' /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml"; then
      nssh "$n" "sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml"
      changed=1
    fi
    if [[ $changed -eq 1 ]]; then
      log "  $n: static pods re-binding — waiting for etcd/scheduler/cm to return ..."
      sleep 10
      retry 30 5 nssh "$n" "curl -fsk --max-time 3 https://127.0.0.1:6443/readyz >/dev/null" \
        || die "$n API not healthy after metrics re-bind"
      retry 20 5 nssh "$n" "curl -fs --max-time 3 http://127.0.0.1:2381/metrics >/dev/null" \
        || die "$n etcd metrics endpoint not answering"
      log "  $n: control-plane metrics exposed"
    else
      log "  $n: already exposed"
    fi
  done
}
log "1/7 exposing control-plane metrics (etcd, scheduler, controller-manager) ..."
expose_cp_metrics

# ---------------------------------------------------- 2. kube-prometheus-stack
log "2/7 kube-prometheus-stack (Prometheus + Alertmanager + Grafana) ..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
helm repo update prometheus-community grafana open-telemetry >/dev/null

if [[ ! -s "$STATE_DIR/grafana-admin.pass" ]]; then
  openssl rand -base64 18 | tr -d '/+=' > "$STATE_DIR/grafana-admin.pass"
  chmod 600 "$STATE_DIR/grafana-admin.pass"
fi
GRAFANA_ADMIN_PASS="$(cat "$STATE_DIR/grafana-admin.pass")"
export GRAFANA_ADMIN_PASS
render "$LAB_DIR/config/observability/kube-prometheus-stack-values.yaml.tpl" \
       "$GEN_DIR/kps-values.yaml" GRAFANA_ADMIN_PASS

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace "$NS" --create-namespace \
  -f "$GEN_DIR/kps-values.yaml" \
  --wait --timeout 15m >/dev/null
log "  kube-prometheus-stack up (grafana admin password: .state/grafana-admin.pass)"

# ---------------------------------------------------- 3. Cilium ServiceMonitors
log "3/7 enabling Cilium/Hubble/Envoy metrics + ServiceMonitors ..."
export API_VIP POD_CIDR
render "$LAB_DIR/config/cilium-values.yaml.tpl" "$GEN_DIR/cilium-values.yaml" API_VIP POD_CIDR
helm upgrade cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  -f "$GEN_DIR/cilium-values.yaml" >/dev/null
cilium status --wait --wait-duration 8m >/dev/null
log "  cilium healthy with metrics enabled"

# ---------------------------------------------------- 4. Loki + Alloy (logs)
log "4/7 Loki (log store) + Alloy (collector) ..."
helm upgrade --install loki grafana/loki \
  --namespace "$NS" -f "$LAB_DIR/config/observability/loki-values.yaml" \
  --wait --timeout 10m >/dev/null
helm upgrade --install alloy grafana/alloy \
  --namespace "$NS" -f "$LAB_DIR/config/observability/alloy-values.yaml" \
  --wait --timeout 5m >/dev/null
log "  logging pipeline up"

# ---------------------------------------------------- 5. Tempo + OTel (traces)
log "5/7 Tempo (trace store) + OpenTelemetry Collector ..."
helm upgrade --install tempo grafana/tempo \
  --namespace "$NS" -f "$LAB_DIR/config/observability/tempo-values.yaml" \
  --wait --timeout 10m >/dev/null
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "$NS" -f "$LAB_DIR/config/observability/otel-collector-values.yaml" \
  --wait --timeout 5m >/dev/null
log "  tracing pipeline up"

# ---------------------------------------------------- 6. Gateway routes
log "6/7 gateway routes (grafana/prometheus/alertmanager .k8s.lab) ..."
kubectl apply -f "$LAB_DIR/manifests/observability-routes.yaml" >/dev/null

# ---------------------------------------------------- 7. app tracing + verify
log "7/7 wiring podinfo -> OTel Collector ..."
kubectl -n default set env deploy/podinfo \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc:4317 \
  OTEL_SERVICE_NAME=podinfo >/dev/null
kubectl -n default rollout status deploy/podinfo --timeout=180s >/dev/null

log "verification ..."
fail=0
vchk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then printf '  \e[32m✔\e[0m %s\n' "$d"; else printf '  \e[31m✘\e[0m %s\n' "$d"; fail=1; fi; }

vchk "all $NS pods running" bash -c "! kubectl -n $NS get pods --no-headers | grep -vE 'Running|Completed'"
vchk "grafana healthy via gateway" \
  curl -fsk --max-time 8 "https://grafana.k8s.lab/api/health"
vchk "loki ready (in-cluster)" \
  kubectl -n "$NS" run vrfy-loki --rm -i --restart=Never --quiet --image=curlimages/curl:8.10.1 -- \
    -fsS --max-time 8 http://loki.observability.svc:3100/ready
vchk "tempo ready (in-cluster)" \
  kubectl -n "$NS" run vrfy-tempo --rm -i --restart=Never --quiet --image=curlimages/curl:8.10.1 -- \
    -fsS --max-time 8 http://tempo.observability.svc:3200/ready
vchk "test traces accepted (telemetrygen -> otel -> tempo)" \
  kubectl -n "$NS" run vrfy-traces --rm -i --restart=Never --quiet \
    --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
    traces --otlp-endpoint otel-collector.observability.svc:4317 --otlp-insecure --traces 10

[[ $fail -eq 0 ]] || warn "some verification checks failed — see above"
stage_done observability
log "observability stack installed — docs/50-observability.md | https://grafana.k8s.lab (admin / \$(cat .state/grafana-admin.pass))"
