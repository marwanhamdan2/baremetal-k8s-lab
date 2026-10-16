// Package obs is the observability bootstrap every microshop service shares —
// the pattern you would put in a company-internal library:
//
//   - OTLP/gRPC trace exporter (endpoint + service name from standard
//     OTEL_* env vars, so deployments configure everything)
//   - W3C trace-context + baggage propagation (the header contract that
//     makes spans from different services join into ONE trace)
//   - slog JSON logging that stamps trace_id/span_id on every line written
//     with a context — which is what makes Loki⇄Tempo correlation work
//   - an HTTP server wrapper (span per request) and client (context
//     propagation) built on otelhttp
package obs

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkresource "go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// Init wires the global tracer provider, propagators and logger.
// Returns the tracer-provider shutdown (flushes buffered spans).
func Init(ctx context.Context) (func(context.Context) error, error) {
	exp, err := otlptracegrpc.New(ctx) // reads OTEL_EXPORTER_OTLP_ENDPOINT
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		// Default() honors OTEL_SERVICE_NAME + OTEL_RESOURCE_ATTRIBUTES
		sdktrace.WithResource(sdkresource.Default()),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{}))

	slog.SetDefault(slog.New(&traceHandler{
		Handler: slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}),
	}))
	return tp.Shutdown, nil
}

// traceHandler adds trace_id/span_id to every log record carrying a span
// context — use slog.InfoContext(ctx, ...) and correlation comes for free.
type traceHandler struct{ slog.Handler }

func (h *traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.Handler.Handle(ctx, r)
}
func (h *traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &traceHandler{h.Handler.WithAttrs(attrs)}
}
func (h *traceHandler) WithGroup(name string) slog.Handler {
	return &traceHandler{h.Handler.WithGroup(name)}
}

// Serve runs an HTTP server whose every request gets a span named
// "METHOD /path", with graceful shutdown on ctx cancellation.
func Serve(ctx context.Context, addr string, mux http.Handler) error {
	handler := otelhttp.NewHandler(mux, "http.server",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}))
	srv := &http.Server{Addr: addr, Handler: handler, ReadHeaderTimeout: 5 * time.Second}

	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	slog.Info("listening", "addr", addr)
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(shutCtx)
	}
}

// Client returns an http.Client that injects the trace context into
// outgoing requests (pass the inbound request's ctx when building requests).
func Client() *http.Client {
	return &http.Client{
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		Timeout:   10 * time.Second,
	}
}

// Getenv with default.
func Getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
