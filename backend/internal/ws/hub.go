// Package ws is the WebSocket hub: it authenticates sockets, enforces pairing,
// routes opaque E2EE frames, drains the offline queue and wakes dozing phones.
// It never sees plaintext — only routing headers (spec §7.4 zero-knowledge).
package ws

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/time/rate"

	"github.com/sarathkumar-21/phone-pigeon/backend/internal/auth"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/config"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/db"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/fcm"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/metrics"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/queue"
)

// Frame mirrors the clients' WireFrame JSON. Ciphertext stays base64 and is never decoded.
type Frame struct {
	Envelope *Envelope `json:"envelope,omitempty"`
	PairAck  *PairAck  `json:"pair_ack,omitempty"`
	Ack      *string   `json:"ack,omitempty"`
}

type Envelope struct {
	MessageID         string `json:"message_id"`
	SenderDeviceID    string `json:"sender_device_id"`
	TargetDeviceID    string `json:"target_device_id"`
	Nonce             string `json:"nonce"`
	Ciphertext        string `json:"ciphertext"`
	ServerTimestampMs int64  `json:"server_timestamp_ms"`
	RequiresWakeup    bool   `json:"requires_wakeup"`
}

type PairAck struct {
	SessionID       string `json:"session_id"`
	AndroidDeviceID string `json:"android_device_id"`
	AndroidPubKey   string `json:"android_pub_key"`
	Nonce           string `json:"nonce"`
	Ciphertext      string `json:"ciphertext"`
}

const maxFrame = 1 << 20 // control-plane frames only; media never transits the relay (spec §6.2)

type Hub struct {
	cfg    config.Config
	store  db.Store
	broker queue.Broker
	waker  fcm.Waker

	mu      sync.RWMutex
	clients map[string]*client

	pairMu    sync.Mutex
	pairCache map[string]time.Time

	upgrader websocket.Upgrader
}

func NewHub(cfg config.Config, store db.Store, broker queue.Broker, waker fcm.Waker) *Hub {
	return &Hub{
		cfg: cfg, store: store, broker: broker, waker: waker,
		clients:   map[string]*client{},
		pairCache: map[string]time.Time{},
		upgrader: websocket.Upgrader{
			ReadBufferSize: 16 << 10, WriteBufferSize: 16 << 10,
			// Native apps only; they don't send Origin. Reject browsers to block cross-site sockets.
			CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" },
		},
	}
}

type client struct {
	id       string
	platform auth.Platform
	conn     *websocket.Conn
	send     chan []byte
	limiter  *rate.Limiter
	done     chan struct{}
	once     sync.Once
}

func (c *client) close() { c.once.Do(func() { close(c.done); _ = c.conn.Close() }) }

// trySend never blocks the router; a full buffer means a stuck socket, so the frame is queued instead.
func (c *client) trySend(b []byte) bool {
	select {
	case <-c.done:
		return false
	case c.send <- b:
		return true
	default:
		return false
	}
}

// ServeWS upgrades an authenticated request and runs the connection until it closes.
func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request, claims *auth.Claims) {
	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		slog.Warn("ws upgrade failed", "device", shortID(claims.Subject), "err", err)
		return
	}
	perSec := rate.Limit(float64(h.cfg.RatePerMinute) / 60)
	c := &client{id: claims.Subject, platform: claims.Platform, conn: conn, send: make(chan []byte, 512),
		limiter: rate.NewLimiter(perSec, h.cfg.RateBurst), done: make(chan struct{})}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// One socket per device: a reconnect replaces the old one.
	h.mu.Lock()
	if old := h.clients[c.id]; old != nil {
		old.close()
	}
	h.clients[c.id] = c
	h.mu.Unlock()
	metrics.ActiveConnections.Inc()
	slog.Info("ws connected", "device", shortID(c.id), "platform", c.platform)
	_ = h.store.Touch(ctx, c.id)
	_ = h.broker.SetPresence(ctx, c.id, h.cfg.InstanceID, 2*(h.cfg.PingInterval+h.cfg.PongTimeout))

	sub, unsubscribe, err := h.broker.Subscribe(ctx, c.id)
	if err != nil {
		slog.Error("subscribe failed", "err", err)
		c.close()
	}

	defer func() {
		h.mu.Lock()
		if h.clients[c.id] == c {
			delete(h.clients, c.id)
			_ = h.broker.ClearPresence(context.Background(), c.id, h.cfg.InstanceID)
		}
		h.mu.Unlock()
		if unsubscribe != nil {
			unsubscribe()
		}
		metrics.ActiveConnections.Dec()
		slog.Info("ws disconnected", "device", shortID(c.id), "platform", c.platform)
		c.close()
	}()

	// Spec §10.2.3: drain the offline queue FIFO before live traffic.
	if queued, err := h.broker.Drain(ctx, c.id); err == nil {
		metrics.OfflineQueueDepth.Sub(float64(len(queued)))
		for _, f := range queued {
			if !c.trySend(f) {
				_, _ = h.broker.Enqueue(ctx, c.id, f)
			}
		}
	}
	if sub != nil {
		go func() {
			for f := range sub {
				if !c.trySend(f) {
					_, _ = h.broker.Enqueue(context.Background(), c.id, f)
				}
			}
		}()
	}

	go h.writeLoop(c)
	h.readLoop(ctx, c)
}

func (h *Hub) writeLoop(c *client) {
	ping := time.NewTicker(h.cfg.PingInterval)
	defer ping.Stop()
	for {
		select {
		case <-c.done:
			return
		case f := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.BinaryMessage, f); err != nil {
				_, _ = h.broker.Enqueue(context.Background(), c.id, f) // don't lose in-flight frames
				c.close()
				return
			}
		case <-ping.C:
			// Spec §10.3: ping every 25s, close after a 10s pong timeout.
			_ = c.conn.SetWriteDeadline(time.Now().Add(h.cfg.PongTimeout))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				c.close()
				return
			}
			_ = h.broker.SetPresence(context.Background(), c.id, h.cfg.InstanceID, 2*(h.cfg.PingInterval+h.cfg.PongTimeout))
		}
	}
}

func (h *Hub) readLoop(ctx context.Context, c *client) {
	c.conn.SetReadLimit(maxFrame)
	deadline := h.cfg.PingInterval + h.cfg.PongTimeout
	_ = c.conn.SetReadDeadline(time.Now().Add(deadline))
	c.conn.SetPongHandler(func(string) error { return c.conn.SetReadDeadline(time.Now().Add(deadline)) })
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		_ = c.conn.SetReadDeadline(time.Now().Add(deadline))
		if !c.limiter.Allow() {
			metrics.RateLimited.Inc()
			continue
		}
		var f Frame
		if json.Unmarshal(data, &f) != nil {
			metrics.EnvelopesRelayed.WithLabelValues("malformed").Inc()
			continue
		}
		switch {
		case f.Envelope != nil:
			h.routeEnvelope(ctx, c, f.Envelope)
		case f.PairAck != nil:
			h.routePairAck(ctx, c, f.PairAck)
		}
	}
}

func (h *Hub) routeEnvelope(ctx context.Context, c *client, e *Envelope) {
	if e.SenderDeviceID != c.id {
		metrics.EnvelopesRelayed.WithLabelValues("spoofed_sender").Inc()
		return
	}
	if !h.paired(ctx, c.id, e.TargetDeviceID) {
		metrics.EnvelopesRelayed.WithLabelValues("not_paired").Inc()
		return
	}
	e.ServerTimestampMs = time.Now().UnixMilli()
	b, _ := json.Marshal(Frame{Envelope: e})
	h.Deliver(ctx, e.TargetDeviceID, b, e.RequiresWakeup)
}

// PairAck carries no target: it goes to the Mac whose pairing session this phone just redeemed.
func (h *Hub) routePairAck(ctx context.Context, c *client, p *PairAck) {
	if c.platform != auth.Android || p.AndroidDeviceID != c.id {
		metrics.EnvelopesRelayed.WithLabelValues("spoofed_sender").Inc()
		return
	}
	mac, err := h.store.LatestMacFor(ctx, c.id)
	if err != nil {
		metrics.EnvelopesRelayed.WithLabelValues("not_paired").Inc()
		return
	}
	b, _ := json.Marshal(Frame{PairAck: p})
	h.Deliver(ctx, mac, b, false)
}

// Deliver: local socket → another instance via Pub/Sub → offline queue (+ FCM wake-up).
func (h *Hub) Deliver(ctx context.Context, target string, frame []byte, wake bool) {
	h.mu.RLock()
	local := h.clients[target]
	h.mu.RUnlock()
	if local != nil && local.trySend(frame) {
		metrics.EnvelopesRelayed.WithLabelValues("delivered").Inc()
		return
	}
	if online, _ := h.broker.Online(ctx, target); online {
		if ok, err := h.broker.Publish(ctx, target, frame); err == nil && ok {
			metrics.EnvelopesRelayed.WithLabelValues("published").Inc()
			return
		}
	}
	if _, err := h.broker.Enqueue(ctx, target, frame); err != nil {
		slog.Error("enqueue failed", "err", err)
		metrics.EnvelopesRelayed.WithLabelValues("dropped").Inc()
		return
	}
	metrics.OfflineQueueDepth.Inc()
	metrics.EnvelopesRelayed.WithLabelValues("queued").Inc()
	if wake {
		h.wake(ctx, target)
	}
}

func (h *Hub) wake(ctx context.Context, id string) {
	d, err := h.store.GetDevice(ctx, id)
	if err != nil || d.Platform != string(auth.Android) || d.FCMToken == "" {
		return
	}
	if ok, _ := h.broker.Allow(ctx, "wake:"+id, 10*time.Second); !ok {
		return
	}
	go func() {
		if h.waker.Wake(context.Background(), d.FCMToken) == nil {
			metrics.FCMWakeups.Inc()
		}
	}()
}

func (h *Hub) paired(ctx context.Context, a, b string) bool {
	key := a + "|" + b
	h.pairMu.Lock()
	if exp, ok := h.pairCache[key]; ok && time.Now().Before(exp) {
		h.pairMu.Unlock()
		return true
	}
	h.pairMu.Unlock()
	ok, err := h.store.ArePaired(ctx, a, b)
	if err != nil || !ok {
		return false
	}
	h.pairMu.Lock()
	if len(h.pairCache) >= 10_000 { // bounded: drop expired entries, then everything if still full
		now := time.Now()
		for k, exp := range h.pairCache {
			if now.After(exp) {
				delete(h.pairCache, k)
			}
		}
		if len(h.pairCache) >= 10_000 {
			h.pairCache = map[string]time.Time{}
		}
	}
	h.pairCache[key] = time.Now().Add(time.Minute)
	h.pairMu.Unlock()
	return true
}

// Disconnect closes a device's socket on this instance (used when its tokens are revoked).
func (h *Hub) Disconnect(id string) {
	h.mu.RLock()
	c := h.clients[id]
	h.mu.RUnlock()
	if c != nil {
		c.close()
	}
}

// ForgetPairing drops cached authorisation after an unpair.
func (h *Hub) ForgetPairing(a, b string) {
	h.pairMu.Lock()
	delete(h.pairCache, a+"|"+b)
	delete(h.pairCache, b+"|"+a)
	h.pairMu.Unlock()
}

// Connected reports whether a device has a socket on this instance (tests, health).
func (h *Hub) Connected(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.clients[id] != nil
}

// shortID keeps logs useful without printing full device identifiers.
func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
