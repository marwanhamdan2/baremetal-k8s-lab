// catalog — product lookups from Postgres with a Redis cache-aside layer.
// The tracing showpiece: a cache HIT trace is 2 spans, a MISS shows the
// Redis GET, the SQL query (otelpgx) and the Redis SET, all as children.
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/extra/redisotel/v9"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel/trace"

	"k8slab.dev/microshop/internal/obs"
)

type product struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	Emoji      string `json:"emoji"`
	PriceCents int64  `json:"price_cents"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, err := obs.Init(ctx)
	if err != nil {
		slog.Error("otel init failed", "err", err)
		os.Exit(1)
	}
	defer shutdown(context.Background())

	// Postgres via pgx, instrumented with otelpgx (span per query, incl. SQL)
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

	// Redis, instrumented with the official redisotel hook
	rdb := redis.NewClient(&redis.Options{Addr: obs.Getenv("REDIS_ADDR", "redis:6379")})
	if err := redisotel.InstrumentTracing(rdb); err != nil {
		slog.Error("redisotel failed", "err", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	mux.HandleFunc("GET /products", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		span := trace.SpanFromContext(ctx)

		// cache-aside: try Redis first
		if val, err := rdb.Get(ctx, "products:all").Result(); err == nil {
			span.AddEvent("cache.hit")
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Cache", "HIT")
			_, _ = w.Write([]byte(val))
			return
		}
		span.AddEvent("cache.miss")

		rows, err := pool.Query(ctx, `SELECT id, name, emoji, price_cents FROM products ORDER BY id`)
		if err != nil {
			slog.ErrorContext(ctx, "query products failed", "err", err)
			http.Error(w, `{"error":"db"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		var out []product
		for rows.Next() {
			var p product
			if err := rows.Scan(&p.ID, &p.Name, &p.Emoji, &p.PriceCents); err != nil {
				slog.ErrorContext(ctx, "scan failed", "err", err)
				http.Error(w, `{"error":"db"}`, http.StatusInternalServerError)
				return
			}
			out = append(out, p)
		}
		b, _ := json.Marshal(out)
		rdb.Set(ctx, "products:all", b, 30*time.Second) // short TTL: watch HIT/MISS alternate
		slog.InfoContext(ctx, "products served from db", "count", len(out))
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "MISS")
		_, _ = w.Write(b)
	})

	mux.HandleFunc("GET /products/{id}", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		id := r.PathValue("id")
		span := trace.SpanFromContext(ctx)

		key := "products:" + id
		if val, err := rdb.Get(ctx, key).Result(); err == nil {
			span.AddEvent("cache.hit")
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Cache", "HIT")
			_, _ = w.Write([]byte(val))
			return
		}
		span.AddEvent("cache.miss")

		var p product
		err := pool.QueryRow(ctx,
			`SELECT id, name, emoji, price_cents FROM products WHERE id = $1`, id).
			Scan(&p.ID, &p.Name, &p.Emoji, &p.PriceCents)
		if err != nil {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		b, _ := json.Marshal(p)
		rdb.Set(ctx, key, b, 30*time.Second)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "MISS")
		_, _ = w.Write(b)
	})

	if err := obs.Serve(ctx, ":8080", mux); err != nil && err != http.ErrServerClosed {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}
