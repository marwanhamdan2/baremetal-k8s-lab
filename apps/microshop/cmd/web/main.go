// web — the frontend edge: serves the UI and reverse-proxies /api/* to the
// api service. As the first traced hop it stamps X-Trace-Id on responses,
// which the UI displays — copy it straight into Grafana → Tempo.
package main

import (
	"context"
	_ "embed"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"syscall"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"

	"k8slab.dev/microshop/internal/obs"
)

//go:embed index.html
var indexHTML []byte

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, err := obs.Init(ctx)
	if err != nil {
		slog.Error("otel init failed", "err", err)
		os.Exit(1)
	}
	defer shutdown(context.Background())

	apiURL, err := url.Parse(obs.Getenv("API_URL", "http://api:8080"))
	if err != nil {
		slog.Error("bad API_URL", "err", err)
		os.Exit(1)
	}
	proxy := httputil.NewSingleHostReverseProxy(apiURL)
	proxy.Transport = otelhttp.NewTransport(http.DefaultTransport)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	mux.Handle("/api/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if sc := trace.SpanContextFromContext(r.Context()); sc.IsValid() {
			w.Header().Set("X-Trace-Id", sc.TraceID().String())
		}
		proxy.ServeHTTP(w, r)
	}))

	if err := obs.Serve(ctx, ":8080", mux); err != nil && err != http.ErrServerClosed {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
