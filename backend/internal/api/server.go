// Package api exposes the relay's REST + WebSocket endpoints (spec §10.1).
//
//	POST   /v1/devices/challenge   → ephemeral X25519 challenge (proof-of-possession, step 1)
//	POST   /v1/devices/register    → JWT for a device that proved it holds its private key
//	POST   /v1/devices/fcm         → Android push token for Doze wake-ups
//	POST   /v1/pairing-sessions    → Mac announces the QR session_id it is showing (10 min)
//	POST   /v1/pairings            → Android redeems that session_id → device pairing
//	DELETE /v1/pairings/{peer}     → unpair
//	GET    /v1/ws                  → authenticated WebSocket
//	GET    /healthz, /metrics
package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/sarathkumar-21/phone-pigeon/backend/internal/auth"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/db"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/queue"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/ws"
)

const (
	challengeTTL      = 2 * time.Minute
	pairingSessionTTL = 10 * time.Minute
)

// Options tunes the public surface.
type Options struct {
	TrustProxy     bool          // client IP comes from the last X-Forwarded-For hop
	RegisterPerMin int           // unauthenticated challenge/register calls per IP per minute (0 = unlimited)
	TokenTTL       time.Duration // used as the TTL of revocation markers
}

type Server struct {
	issuer  *auth.Issuer
	store   db.Store
	broker  queue.Broker
	hub     *ws.Hub
	opts    Options
	limiter *ipLimiter
}

func New(issuer *auth.Issuer, store db.Store, broker queue.Broker, hub *ws.Hub, opts ...Options) *Server {
	o := Options{RegisterPerMin: 0, TokenTTL: 7 * 24 * time.Hour}
	if len(opts) > 0 {
		o = opts[0]
		if o.TokenTTL <= 0 {
			o.TokenTTL = 7 * 24 * time.Hour
		}
	}
	return &Server{issuer: issuer, store: store, broker: broker, hub: hub, opts: o, limiter: newIPLimiter(o.RegisterPerMin)}
}

// MetricsHandler serves Prometheus metrics; mount it on a separate, private listener (never the public mux).
func MetricsHandler() http.Handler { return promhttp.Handler() }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/devices/challenge", s.limited(s.challenge))
	mux.HandleFunc("POST /v1/devices/register", s.limited(s.register))
	mux.HandleFunc("POST /v1/devices/fcm", s.authed(s.fcmToken))
	mux.HandleFunc("POST /v1/pairing-sessions", s.authed(s.pairingSession))
	mux.HandleFunc("POST /v1/pairings", s.authed(s.pair))
	mux.HandleFunc("DELETE /v1/pairings/{peer}", s.authed(s.unpair))
	mux.HandleFunc("GET /v1/ws", s.authed(func(w http.ResponseWriter, r *http.Request, c *auth.Claims) { s.hub.ServeWS(w, r, c) }))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
	return logRequests(mux)
}

// ---------------------------------------------------------------- devices

type challengeReq struct {
	DeviceID  string        `json:"device_id"`
	Platform  auth.Platform `json:"platform"`
	PublicKey []byte        `json:"public_key"` // base64 in JSON
}

type challengeRes struct {
	ChallengeID     string `json:"challenge_id"`
	ServerPublicKey []byte `json:"server_public_key"`
	Nonce           []byte `json:"nonce"`
	ExpiresIn       int    `json:"expires_in"`
}

func (s *Server) challenge(w http.ResponseWriter, r *http.Request) {
	var req challengeReq
	if !decode(w, r, &req) {
		return
	}
	if _, err := uuid.Parse(req.DeviceID); err != nil || !req.Platform.Valid() {
		fail(w, http.StatusBadRequest, "device_id must be a UUID and platform ANDROID or MACOS")
		return
	}
	ch, serverPub, err := auth.NewChallenge(req.DeviceID, req.Platform, req.PublicKey)
	if err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	id := uuid.NewString()
	blob, _ := json.Marshal(ch)
	if err := s.broker.Put(r.Context(), "challenge:"+id, blob, challengeTTL); err != nil {
		fail(w, http.StatusInternalServerError, "storage error")
		return
	}
	reply(w, http.StatusOK, challengeRes{ChallengeID: id, ServerPublicKey: serverPub, Nonce: ch.Nonce, ExpiresIn: int(challengeTTL.Seconds())})
}

type registerReq struct {
	ChallengeID string        `json:"challenge_id"`
	Proof       []byte        `json:"proof"`
	DeviceID    string        `json:"device_id,omitempty"`
	Platform    auth.Platform `json:"platform,omitempty"`
	PublicKey   []byte        `json:"public_key,omitempty"`
}

type registerRes struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
	DeviceID  string    `json:"device_id"`
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !decode(w, r, &req) {
		return
	}
	blob, err := s.broker.Take(r.Context(), "challenge:"+req.ChallengeID) // single use
	if err != nil {
		fail(w, http.StatusUnauthorized, "unknown or expired challenge")
		return
	}
	var ch auth.Challenge
	if json.Unmarshal(blob, &ch) != nil || !ch.Verify(req.Proof) ||
		(req.DeviceID != "" && req.DeviceID != ch.DeviceID) ||
		(len(req.PublicKey) > 0 && string(req.PublicKey) != string(ch.PublicKey)) {
		fail(w, http.StatusUnauthorized, "proof of possession failed")
		return
	}
	err = s.store.UpsertDevice(r.Context(), db.Device{ID: ch.DeviceID, Platform: string(ch.Platform), PublicKey: ch.PublicKey})
	if errors.Is(err, db.ErrKeyChanged) {
		fail(w, http.StatusConflict, "device_id is bound to another key; generate a new device_id after rotating keys")
		return
	} else if err != nil {
		fail(w, http.StatusInternalServerError, "storage error")
		return
	}
	tok, exp, err := s.issuer.Issue(ch.DeviceID, ch.Platform)
	if err != nil {
		fail(w, http.StatusInternalServerError, "token error")
		return
	}
	reply(w, http.StatusOK, registerRes{Token: tok, ExpiresAt: exp, DeviceID: ch.DeviceID})
}

func (s *Server) fcmToken(w http.ResponseWriter, r *http.Request, c *auth.Claims) {
	var req struct {
		FCMToken string `json:"fcm_token"`
	}
	if !decode(w, r, &req) {
		return
	}
	if c.Platform != auth.Android || req.FCMToken == "" {
		fail(w, http.StatusBadRequest, "only Android devices register FCM tokens")
		return
	}
	if err := s.store.SetFCMToken(r.Context(), c.Subject, req.FCMToken); err != nil {
		fail(w, http.StatusInternalServerError, "storage error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------- pairing

type sessionReq struct {
	SessionID string `json:"session_id"`
}

func (s *Server) pairingSession(w http.ResponseWriter, r *http.Request, c *auth.Claims) {
	var req sessionReq
	if !decode(w, r, &req) {
		return
	}
	if c.Platform != auth.MacOS || len(req.SessionID) < 32 || len(req.SessionID) > 128 {
		fail(w, http.StatusBadRequest, "only a Mac can open a pairing session, with a 128-bit-or-longer id")
		return
	}
	// Set-if-absent: a second Mac must not be able to replace the Mac bound to a live session id.
	// Re-announcing the same session from the same Mac (reconnects) is fine.
	stored, err := s.broker.PutNX(r.Context(), "pairsess:"+req.SessionID, []byte(c.Subject), pairingSessionTTL)
	if err != nil {
		fail(w, http.StatusInternalServerError, "storage error")
		return
	}
	if !stored {
		if owner, err := s.broker.Get(r.Context(), "pairsess:"+req.SessionID); err != nil || string(owner) != c.Subject {
			fail(w, http.StatusConflict, "pairing session id already in use")
			return
		}
	}
	w.WriteHeader(http.StatusCreated)
}

func (s *Server) pair(w http.ResponseWriter, r *http.Request, c *auth.Claims) {
	var req sessionReq
	if !decode(w, r, &req) {
		return
	}
	if c.Platform != auth.Android {
		fail(w, http.StatusBadRequest, "only a phone can redeem a pairing session")
		return
	}
	mac, err := s.broker.Take(r.Context(), "pairsess:"+req.SessionID) // the QR code's session_id is the capability
	if err != nil {
		fail(w, http.StatusNotFound, "pairing code expired — show a new code on the Mac")
		return
	}
	p, err := s.store.CreatePairing(r.Context(), c.Subject, string(mac))
	if err != nil {
		fail(w, http.StatusInternalServerError, "storage error")
		return
	}
	reply(w, http.StatusCreated, map[string]string{"pairing_id": p.ID, "macos_device_id": p.MacID})
}

func (s *Server) unpair(w http.ResponseWriter, r *http.Request, c *auth.Claims) {
	peer := r.PathValue("peer")
	if err := s.store.DeletePairing(r.Context(), c.Subject, peer); err != nil {
		fail(w, http.StatusInternalServerError, "storage error")
		return
	}
	s.hub.ForgetPairing(c.Subject, peer)
	// Tokens issued before now stop working for both devices (they re-prove key possession to get new ones),
	// and live sockets are dropped so the revocation takes effect immediately.
	s.revoke(r.Context(), c.Subject)
	s.revoke(r.Context(), peer)
	s.hub.Disconnect(c.Subject)
	s.hub.Disconnect(peer)
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------- helpers

func (s *Server) revoke(ctx context.Context, deviceID string) {
	_ = s.broker.Put(ctx, "revoked:"+deviceID, []byte(strconv.FormatInt(time.Now().UnixMilli(), 10)), s.opts.TokenTTL+time.Hour)
}

// revokedAt returns the cut-off before which tokens for the device are void (zero = none).
func (s *Server) revokedAt(ctx context.Context, deviceID string) time.Time {
	v, err := s.broker.Get(ctx, "revoked:"+deviceID)
	if err != nil {
		return time.Time{}
	}
	ms, err := strconv.ParseInt(string(v), 10, 64)
	if err != nil {
		return time.Time{}
	}
	return time.UnixMilli(ms)
}

func (s *Server) limited(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.limiter.allow(clientIP(r, s.opts.TrustProxy)) {
			w.Header().Set("Retry-After", "30")
			fail(w, http.StatusTooManyRequests, "too many requests")
			return
		}
		next(w, r)
	}
}

func (s *Server) authed(next func(http.ResponseWriter, *http.Request, *auth.Claims)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Header only: a token in the URL would end up in proxy and access logs.
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		claims, err := s.issuer.Verify(tok)
		if err != nil {
			fail(w, http.StatusUnauthorized, "invalid token")
			return
		}
		if cut := s.revokedAt(r.Context(), claims.Subject); claims.IssuedAt == nil || !claims.IssuedAt.Time.After(cut) {
			fail(w, http.StatusUnauthorized, "token revoked")
			return
		}
		if _, err := s.store.GetDevice(r.Context(), claims.Subject); err != nil {
			fail(w, http.StatusUnauthorized, "unknown device")
			return
		}
		next(w, r, claims)
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		fail(w, http.StatusBadRequest, "invalid JSON")
		return false
	}
	return true
}

func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) { reply(w, code, map[string]string{"error": msg}) }

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if r.URL.Path != "/v1/ws" && r.URL.Path != "/healthz" && r.URL.Path != "/metrics" {
			slog.Debug("http", "method", r.Method, "path", r.URL.Path, "dur", time.Since(start))
		}
	})
}

// B64 is a helper for clients/tests building JSON by hand.
func B64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

var _ = context.Background
