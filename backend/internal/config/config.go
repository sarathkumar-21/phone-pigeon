// Package config loads relay settings from the environment.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Addr               string        // HTTP listen address, e.g. ":8080"
	JWTSecret          []byte        // HMAC key for device tokens
	TokenTTL           time.Duration // lifetime of issued JWTs
	DatabaseURL        string        // postgres://… ; empty = in-memory store (dev only)
	RedisURL           string        // redis://… ; empty = in-memory broker (single instance)
	FCMCredentialsFile string        // Firebase service-account JSON; empty = wake-ups disabled
	InstanceID         string        // unique per process, used for presence
	OfflineTTL         time.Duration // spec §10.2: 24h
	OfflineCap         int64         // spec §10.2: 500 messages
	RatePerMinute      int           // spec §10.3: 60 envelopes/min
	RateBurst          int           // spec §10.3: burst 20
	PingInterval       time.Duration // spec §10.3: 25s
	PongTimeout        time.Duration // spec §10.3: 10s
	MetricsAddr        string        // separate listener for /metrics; empty = metrics disabled
	TrustProxy         bool          // read the client IP from the last X-Forwarded-For hop (set behind Caddy)
	RegisterPerMin     int           // unauthenticated challenge/register calls per IP per minute
}

func Load() Config {
	c := Config{
		Addr:               env("ADDR", ":8080"),
		DatabaseURL:        os.Getenv("DATABASE_URL"),
		RedisURL:           os.Getenv("REDIS_URL"),
		FCMCredentialsFile: os.Getenv("FCM_CREDENTIALS_FILE"),
		InstanceID:         env("INSTANCE_ID", randomHex(6)),
		TokenTTL:           duration("TOKEN_TTL", 7*24*time.Hour),
		MetricsAddr:        os.Getenv("METRICS_ADDR"),
		TrustProxy:         os.Getenv("TRUST_PROXY") == "1",
		RegisterPerMin:     integer("REGISTER_PER_MIN", 20),
		OfflineTTL:         duration("OFFLINE_TTL", 24*time.Hour),
		OfflineCap:         int64(integer("OFFLINE_CAP", 500)),
		RatePerMinute:      integer("RATE_PER_MINUTE", 60),
		RateBurst:          integer("RATE_BURST", 20),
		PingInterval:       duration("PING_INTERVAL", 25*time.Second),
		PongTimeout:        duration("PONG_TIMEOUT", 10*time.Second),
	}
	insecureDev := os.Getenv("ALLOW_INSECURE_DEV") == "1"
	if s := os.Getenv("JWT_SECRET"); s != "" {
		if len(s) < 32 && !insecureDev {
			slog.Error("JWT_SECRET must be at least 32 bytes (set ALLOW_INSECURE_DEV=1 to override for local development)")
			os.Exit(1)
		}
		c.JWTSecret = []byte(s)
	} else {
		slog.Warn("JWT_SECRET not set — generating an ephemeral secret; tokens will not survive restarts")
		c.JWTSecret = []byte(randomHex(32))
	}
	return c
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func integer(k string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return def
}

func duration(k string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(k)); err == nil {
		return v
	}
	return def
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
