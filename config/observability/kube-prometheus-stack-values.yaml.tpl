# ============================================================================
# kube-prometheus-stack — metrics backbone (Prometheus Operator, Alertmanager,
# Grafana, node-exporter, kube-state-metrics + a full default alert/dashboard
# set). Rendered by scripts/80-observability.sh (var: GRAFANA_ADMIN_PASS).
#
# Lab sizing, prod shape: single replicas with persistence and size-capped
# retention. The prod deltas (HA pairs, Thanos/Mimir for long-term storage)
# are documented in docs/50-observability.md.
# ============================================================================
fullnameOverride: kps

defaultRules:
  create: true
  rules:
    kubeProxy: false          # no kube-proxy in this cluster (Cilium eBPF)

kubeProxy:
  enabled: false              # would be a permanently-down target otherwise

# ---- control-plane scraping (works because 80-observability.sh re-binds
# etcd metrics + scheduler/controller-manager to the cluster network) -------
kubeEtcd:
  enabled: true
  service:
    enabled: true
    port: 2381
    targetPort: 2381
  serviceMonitor:
    scheme: http
kubeScheduler:
  enabled: true
  service:
    enabled: true
    port: 10259
    targetPort: 10259
  serviceMonitor:
    https: true
    insecureSkipVerify: true
kubeControllerManager:
  enabled: true
  service:
    enabled: true
    port: 10257
    targetPort: 10257
  serviceMonitor:
    https: true
    insecureSkipVerify: true

alertmanager:
  alertmanagerSpec:
    retention: 120h
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 2Gi

prometheus:
  prometheusSpec:
    replicas: 1               # prod: 2 replicas + Thanos/Mimir
    retention: 7d
    retentionSize: 15GB
    enableRemoteWriteReceiver: true   # Tempo's metrics-generator writes here
    # scrape EVERY ServiceMonitor/PodMonitor/Rule in the cluster, not only
    # the chart's own (this is how Cilium/Loki/Tempo monitors get picked up)
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 20Gi
    resources:
      requests: { cpu: 200m, memory: 1Gi }

grafana:
  adminPassword: "${GRAFANA_ADMIN_PASS}"
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi
  grafana.ini:
    server:
      root_url: "https://grafana.k8s.lab"
  # Loki + Tempo datasources with cross-signal correlation:
  #   logs -> traces (TraceID derived field), traces -> logs, service graph
  additionalDataSources:
    - name: Loki
      type: loki
      uid: loki
      access: proxy
      url: http://loki.observability.svc:3100
      jsonData:
        derivedFields:
          - name: TraceID
            matcherRegex: '"?trace_?[iI][dD]"?[=:]"?(\w+)"?'
            datasourceUid: tempo
            url: "$${__value.raw}"
    - name: Tempo
      type: tempo
      uid: tempo
      access: proxy
      url: http://tempo.observability.svc:3200   # tempo HTTP is 3200 (3100 = Loki)
      jsonData:
        tracesToLogsV2:
          datasourceUid: loki
          filterByTraceID: true
          spanStartTimeShift: "-5m"
          spanEndTimeShift: "5m"
        serviceMap:
          datasourceUid: prometheus
        nodeGraph:
          enabled: true
