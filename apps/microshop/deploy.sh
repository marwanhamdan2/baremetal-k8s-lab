#!/usr/bin/env bash
# Dev inner loop: edit Go code, run this, watch the new digests roll out.
#   ./deploy.sh            build+push+apply the 4 services
set -Eeuo pipefail
cd "$(dirname "$0")"
LAB_DIR="$(cd ../.. && pwd)"

export PATH="$HOME/.local/go/bin:$HOME/go/bin:$PATH"
export KO_DOCKER_REPO="10.20.0.210/microshop"
export SSL_CERT_FILE="$LAB_DIR/.state/lab-ca.crt"

go mod tidy
ko resolve --platform=linux/amd64 -f deploy/apps.yaml | kubectl apply -f -
for d in web api catalog orders; do kubectl -n microshop rollout status "deploy/$d" --timeout=300s; done
echo "deployed — http://shop.k8s.lab"
