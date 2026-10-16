// orders — places and lists orders. On a placement it calls catalog for the
// price (service-to-service hop with trace propagation), then INSERTs into
// Postgres. `?fail=1` triggers a synthetic 500 so you can practice hunting
// error traces (red spans) in Tempo.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"

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

	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		slog.Error("bad DATABASE_URL", "err", err)
		os.Exit(1)
	}
	cfg.ConnConfig.Tracer = otelpgx.NewTracer()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		slog.Error("pg connect failed", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	catalogURL := obs.Getenv("CATALOG_URL", "http://catalog:8080")
	httpc := obs.Client()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	mux.HandleFunc("POST /orders", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		if r.URL.Query().Get("fail") == "1" {
			slog.ErrorContext(ctx, "synthetic failure requested (chaos knob)")
			http.Error(w, `{"error":"synthetic failure (fail=1)"}`, http.StatusInternalServerError)
			return
		}

		var req struct {
			ProductID int64 `json:"product_id"`
			Qty       int   `json:"qty"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
			return
		}
		if req.Qty < 1 {
			req.Qty = 1
		}

		// price lookup via catalog — the trace context rides along
		creq, _ := http.NewRequestWithContext(ctx, http.MethodGet,
			fmt.Sprintf("%s/products/%d", catalogURL, req.ProductID), nil)
		cresp, err := httpc.Do(creq)
		if err != nil {
			slog.ErrorContext(ctx, "catalog call failed", "err", err)
			http.Error(w, `{"error":"catalog unavailable"}`, http.StatusBadGateway)
			return
		}
		defer cresp.Body.Close()
		if cresp.StatusCode != http.StatusOK {
			http.Error(w, `{"error":"unknown product"}`, http.StatusBadRequest)
			return
		}
		var p struct {
			PriceCents int64 `json:"price_cents"`
		}
		if err := json.NewDecoder(cresp.Body).Decode(&p); err != nil {
			http.Error(w, `{"error":"catalog response"}`, http.StatusBadGateway)
			return
		}

		total := p.PriceCents * int64(req.Qty)
		var id int64
		err = pool.QueryRow(ctx,
			`INSERT INTO orders (product_id, qty, total_cents) VALUES ($1, $2, $3) RETURNING id`,
			req.ProductID, req.Qty, total).Scan(&id)
		if err != nil {
			slog.ErrorContext(ctx, "insert order failed", "err", err)
			http.Error(w, `{"error":"db"}`, http.StatusInternalServerError)
			return
		}
		slog.InfoContext(ctx, "order placed", "order_id", id, "product_id", req.ProductID, "qty", req.Qty, "total_cents", total)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"id": id, "total_cents": total})
	})

	mux.HandleFunc("GET /orders", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		rows, err := pool.Query(ctx, `
			SELECT o.id, p.name, p.emoji, o.qty, o.total_cents, to_char(o.created_at, 'HH24:MI:SS') AS at
			FROM orders o JOIN products p ON p.id = o.product_id
			ORDER BY o.id DESC LIMIT 20`)
		if err != nil {
			slog.ErrorContext(ctx, "query orders failed", "err", err)
			http.Error(w, `{"error":"db"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		type row struct {
			ID         int64  `json:"id"`
			Name       string `json:"name"`
			Emoji      string `json:"emoji"`
			Qty        int    `json:"qty"`
			TotalCents int64  `json:"total_cents"`
			At         string `json:"at"`
		}
		var out []row
		for rows.Next() {
			var x row
			if err := rows.Scan(&x.ID, &x.Name, &x.Emoji, &x.Qty, &x.TotalCents, &x.At); err != nil {
				http.Error(w, `{"error":"db"}`, http.StatusInternalServerError)
				return
			}
			out = append(out, x)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})

	if err := obs.Serve(ctx, ":8080", mux); err != nil && err != http.ErrServerClosed {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
