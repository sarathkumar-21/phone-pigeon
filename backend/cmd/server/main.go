// Command server runs the PhonePigeon cloud relay: REST pairing/auth, an E2EE
// WebSocket hub, Redis Pub/Sub + 24h offline queue, and FCM Doze wake-ups.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sarathkumar-21/phone-pigeon/backend/internal/api"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/auth"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/config"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/db"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/fcm"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/queue"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/ws"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	cfg := config.Load()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var store db.Store = db.NewMemory()
	if cfg.DatabaseURL != "" {
		pg, err := db.OpenPostgres(ctx, cfg.DatabaseURL)
		if err != nil {
			slog.Error("postgres", "err", err)
			os.Exit(1)
		}
		store = pg
	} else {
		slog.Warn("DATABASE_URL not set — using in-memory store (development only)")
	}
	defer store.Close()

	var broker queue.Broker = queue.NewMemory(cfg.OfflineTTL, cfg.OfflineCap)
	if cfg.RedisURL != "" {
		r, err := queue.NewRedis(cfg.RedisURL, cfg.OfflineTTL, cfg.OfflineCap)
		if err != nil {
			slog.Error("redis", "err", err)
			os.Exit(1)
		}
		broker = r
	} else {
		slog.Warn("REDIS_URL not set — single-instance in-memory routing (development only)")
	}
	defer broker.Close()

	var waker fcm.Waker = fcm.Noop{}
	if cfg.FCMCredentialsFile != "" {
		f, err := fcm.NewFirebase(ctx, cfg.FCMCredentialsFile)
		if err != nil {
			slog.Error("firebase", "err", err)
			os.Exit(1)
		}
		waker = f
	} else {
		slog.Warn("FCM_CREDENTIALS_FILE not set — Doze wake-ups disabled")
	}

	hub := ws.NewHub(cfg, store, broker, waker)
	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler: api.New(auth.NewIssuer(cfg.JWTSecret, cfg.TokenTTL), store, broker, hub,
			api.Options{TrustProxy: cfg.TrustProxy, RegisterPerMin: cfg.RegisterPerMin, TokenTTL: cfg.TokenTTL}).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second, // gorilla clears these deadlines when it hijacks the WebSocket
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	if cfg.MetricsAddr != "" {
		go func() {
			mux := http.NewServeMux()
			mux.Handle("/metrics", api.MetricsHandler())
			slog.Info("metrics listening", "addr", cfg.MetricsAddr)
			if err := (&http.Server{Addr: cfg.MetricsAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe(); err != nil {
				slog.Error("metrics listen", "err", err)
			}
		}()
	}
	go func() {
		slog.Info("phonepigeon-relay listening", "addr", cfg.Addr, "instance", cfg.InstanceID)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("listen", "err", err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
}
