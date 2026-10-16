// api — the BFF (backend-for-frontend): a thin fan-out layer in front of
// catalog and orders. Exists so the trace shows a realistic multi-tier
// call chain: web -> api -> {catalog, orders}.
package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"k8slab.dev/microshop/internal/obs"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, err := obs.Init(ctx)
	if err != nil {
		slog.Error("otel init failed", "err", err)
		os.Exit(1)
	}
	defer shutdown(context.Background())

	catalogURL := obs.Getenv("CATALOG_URL", "http://catalog:8080")
	ordersURL := obs.Getenv("ORDERS_URL", "http://orders:8080")
	httpc := obs.Client()

	// forward relays a request upstream, preserving method, body, query and
	// (crucially, via obs.Client) the trace context.
	forward := func(w http.ResponseWriter, r *http.Request, target string) {
		req, err := http.NewRequestWithContext(r.Context(), r.Method, target, r.Body)
		if err != nil {
			http.Error(w, `{"error":"bad upstream request"}`, http.StatusInternalServerError)
			return
		}
		req.URL.RawQuery = r.URL.RawQuery
		req.Header.Set("Content-Type", r.Header.Get("Content-Type"))
		resp, err := httpc.Do(req)
		if err != nil {
			slog.ErrorContext(r.Context(), "upstream failed", "target", target, "err", err)
			http.Error(w, `{"error":"upstream unavailable"}`, http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		if v := resp.Header.Get("Content-Type"); v != "" {
			w.Header().Set("Content-Type", v)
		}
		if v := resp.Header.Get("X-Cache"); v != "" {
			w.Header().Set("X-Cache", v)
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /api/products", func(w http.ResponseWriter, r *http.Request) { forward(w, r, catalogURL+"/products") })
	mux.HandleFunc("GET /api/orders", func(w http.ResponseWriter, r *http.Request) { forward(w, r, ordersURL+"/orders") })
	mux.HandleFunc("POST /api/orders", func(w http.ResponseWriter, r *http.Request) { forward(w, r, ordersURL+"/orders") })

	if err := obs.Serve(ctx, ":8080", mux); err != nil && err != http.ErrServerClosed {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
