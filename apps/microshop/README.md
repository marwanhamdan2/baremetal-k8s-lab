# microshop — the traced fullstack demo

Four Go microservices + Postgres (CloudNativePG) + Redis, every hop
OpenTelemetry-instrumented. Full walkthrough: [docs/70-microshop-tracing.md](../../docs/70-microshop-tracing.md).

```text
browser ── gateway (Cilium Envoy, :80/:443)
              └─ web      UI + /api reverse-proxy, stamps X-Trace-Id
                   └─ api       BFF fan-out
                        ├─ catalog   Redis cache-aside over Postgres reads
                        └─ orders ──┐ price check via catalog, INSERT order
                                    └─ shop-db (CNPG primary+replica) · redis
```

| Path | What it teaches |
|---|---|
| [internal/obs/obs.go](internal/obs/obs.go) | the shared observability bootstrap: OTLP exporter, W3C propagation, slog with trace ids |
| [cmd/web](cmd/web/main.go) | edge service: embedded UI, traced reverse proxy, exposing the trace id to users |
| [cmd/api](cmd/api/main.go) | BFF pattern; context-propagating HTTP client |
| [cmd/catalog](cmd/catalog/main.go) | otelpgx (SQL spans) + redisotel (cache spans) + cache HIT/MISS span events |
| [cmd/orders](cmd/orders/main.go) | service→service call inside a request, error traces via `?fail=1` |
| [deploy/](deploy/) | CNPG `Cluster`, Redis StatefulSet, ko-built Deployments, HTTPRoute |

## Dev loop

```bash
./deploy.sh     # go mod tidy -> ko build/push (lab registry) -> kubectl apply -> rollout
```

No Docker involved: `ko` compiles each `cmd/` into a distroless image and
pushes to the lab registry at `10.20.0.210` (TLS via the lab CA). Images are
referenced by digest, so every deploy is exact.

## Poke it

```bash
open http://shop.k8s.lab                  # UI (shows the trace id per action)
curl -s http://shop.k8s.lab/api/products | jq          # watch X-Cache: HIT/MISS
curl -s -X POST http://shop.k8s.lab/api/orders -H 'Content-Type: application/json' \
     -d '{"product_id":1,"qty":2}' -D - -o /dev/null | grep -i x-trace-id
curl -s -X POST 'http://shop.k8s.lab/api/orders?fail=1' -d '{}' # error trace
```
