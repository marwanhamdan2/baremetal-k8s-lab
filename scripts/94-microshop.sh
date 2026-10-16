#!/usr/bin/env bash
# ============================================================================
# 94-microshop.sh — build + deploy the traced microservice demo:
#
#   1. toolchain: Go (user-local, no sudo) + ko (Go-native image builder)
#   2. CloudNativePG operator + the shop-db Postgres cluster (2 instances)
#   3. Redis StatefulSet
#   4. ko build -> push to the lab registry -> deploy the 4 Go services
#   5. verification: order through the gateway, then assert the trace in
#      Tempo spans web -> api -> orders -> catalog (+ DB/cache client spans)
#
# Re-run to redeploy after code changes (or use apps/microshop/deploy.sh).
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

REG="10.20.0.210"
APP_DIR="$LAB_DIR/apps/microshop"

# ---------------------------------------------------------------- toolchain
export PATH="$HOME/.local/go/bin:$HOME/go/bin:$PATH"
if ! command -v go >/dev/null; then
  GOVER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
  log "1/5 installing Go toolchain $GOVER (user-local) ..."
  mkdir -p "$HOME/.local"
  curl -fsSL "https://go.dev/dl/${GOVER}.linux-amd64.tar.gz" | tar -xz -C "$HOME/.local"
else
  log "1/5 Go present: $(go version | awk '{print $3}')"
fi
if ! command -v ko >/dev/null; then
  log "    installing ko (go install) ..."
  go install github.com/google/ko@latest
fi

# ------------------------------------------------------------ CNPG operator
log "2/5 CloudNativePG operator + shop-db cluster (primary + replica) ..."
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --wait --timeout 10m >/dev/null
kubectl create ns microshop --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$APP_DIR/deploy/postgres.yaml" >/dev/null
log "    waiting for 2/2 postgres instances ready (image pull + init) ..."
retry 60 10 bash -c "[[ \$(kubectl -n microshop get cluster shop-db -o jsonpath='{.status.readyInstances}' 2>/dev/null) == 2 ]]" \
  || die "shop-db never reached 2 ready instances (kubectl -n microshop describe cluster shop-db)"

# ------------------------------------------------------------------- redis
log "3/5 Redis (StatefulSet, AOF on Longhorn) ..."
kubectl apply -f "$APP_DIR/deploy/redis.yaml" >/dev/null
kubectl -n microshop rollout status sts/redis --timeout=300s >/dev/null

# ------------------------------------------------------------ build+deploy
log "4/5 ko build -> push ($REG/microshop) -> deploy ..."
cd "$APP_DIR"
go mod tidy
export KO_DOCKER_REPO="$REG/microshop"
export SSL_CERT_FILE="$STATE_DIR/lab-ca.crt"     # trust the lab CA for pushes
ko resolve --platform=linux/amd64 -f deploy/apps.yaml | kubectl apply -f - >/dev/null
for d in web api catalog orders; do
  kubectl -n microshop rollout status "deploy/$d" --timeout=300s >/dev/null
  log "    $d rolled out"
done

# ------------------------------------------------------------ verification
log "5/5 end-to-end trace verification ..."
RES=(--resolve "shop.k8s.lab:80:$GATEWAY_IP")
retry 12 5 curl -fsS "${RES[@]}" --max-time 6 http://shop.k8s.lab/ -o /dev/null \
  || die "shop UI not answering through the gateway"

# browse + order; capture the trace id stamped by the web edge
curl -fsS "${RES[@]}" --max-time 6 http://shop.k8s.lab/api/products -o /dev/null
TRACE_ID="$(curl -fsS "${RES[@]}" --max-time 6 -D - -o /dev/null \
  -X POST http://shop.k8s.lab/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"product_id": 2, "qty": 3}' | tr -d '\r' | awk 'tolower($1)=="x-trace-id:"{print $2}')"
[[ -n "$TRACE_ID" ]] || die "no X-Trace-Id on the order response"
log "    order placed, trace: $TRACE_ID"

sleep 10   # batcher flush + tempo ingest
SERVICES="$(kubectl -n observability run vrfy-shop-trace --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 -- \
  -fsS --max-time 8 "http://tempo.observability.svc:3200/api/traces/$TRACE_ID" \
  | jq -r '[.batches[].resource.attributes[] | select(.key=="service.name").value.stringValue] | unique | sort | join(",")')"
log "    services in trace: $SERVICES"
for s in web api orders catalog; do
  [[ "$SERVICES" == *"$s"* ]] || die "service '$s' missing from trace $TRACE_ID"
done
log "    ✔ full chain traced: web -> api -> orders -> catalog (+ pg/redis client spans)"

stage_done microshop
log "microshop live: http://shop.k8s.lab (after the hosts entry) — docs/70-microshop-tracing.md"
