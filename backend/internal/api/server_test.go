package api_test

import (
	"bytes"
	"fmt"
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"golang.org/x/crypto/curve25519"

	"github.com/sarathkumar-21/phone-pigeon/backend/internal/api"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/auth"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/config"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/db"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/queue"
	"github.com/sarathkumar-21/phone-pigeon/backend/internal/ws"
)

// ---------------------------------------------------------------- harness

type fakeWaker struct {
	mu     sync.Mutex
	tokens []string
}

func (f *fakeWaker) Wake(_ context.Context, t string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tokens = append(f.tokens, t)
	return nil
}

func (f *fakeWaker) count() int { f.mu.Lock(); defer f.mu.Unlock(); return len(f.tokens) }

func cfg() config.Config {
	return config.Config{JWTSecret: []byte("test-secret"), TokenTTL: time.Hour, InstanceID: uuid.NewString()[:6],
		OfflineTTL: time.Hour, OfflineCap: 500, RatePerMinute: 60, RateBurst: 20,
		PingInterval: 5 * time.Second, PongTimeout: 2 * time.Second}
}

func newServer(t *testing.T, store db.Store, broker queue.Broker, waker *fakeWaker) *httptest.Server {
	t.Helper()
	return newServerOpts(t, store, broker, waker, api.Options{TokenTTL: time.Hour})
}

func newServerOpts(t *testing.T, store db.Store, broker queue.Broker, waker *fakeWaker, o api.Options) *httptest.Server {
	t.Helper()
	c := cfg()
	hub := ws.NewHub(c, store, broker, waker)
	srv := httptest.NewServer(api.New(auth.NewIssuer(c.JWTSecret, c.TokenTTL), store, broker, hub, o).Handler())
	t.Cleanup(srv.Close)
	return srv
}

type device struct {
	id, token string
	priv, pub []byte
}

func post(t *testing.T, url, token string, body any) (*http.Response, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res, out
}

func keypair() (priv, pub []byte) {
	priv = make([]byte, 32)
	_, _ = rand.Read(priv)
	pub, _ = curve25519.X25519(priv, curve25519.Basepoint)
	return
}

// register runs the full challenge → proof → token flow exactly like the apps do.
func register(t *testing.T, base string, p auth.Platform, d *device) *device {
	t.Helper()
	if d == nil {
		priv, pub := keypair()
		d = &device{id: uuid.NewString(), priv: priv, pub: pub}
	}
	res, ch := post(t, base+"/v1/devices/challenge", "", map[string]any{"device_id": d.id, "platform": p, "public_key": d.pub})
	if res.StatusCode != 200 {
		t.Fatalf("challenge %d %v", res.StatusCode, ch)
	}
	serverPub := b64(t, ch["server_public_key"])
	shared, _ := curve25519.X25519(d.priv, serverPub)
	proof := auth.Proof(shared, d.id, b64(t, ch["nonce"]))
	res, reg := post(t, base+"/v1/devices/register", "", map[string]any{"challenge_id": ch["challenge_id"], "proof": proof})
	if res.StatusCode != 200 {
		t.Fatalf("register %d %v", res.StatusCode, reg)
	}
	d.token = reg["token"].(string)
	return d
}

func b64(t *testing.T, v any) []byte {
	var b []byte
	raw, _ := json.Marshal(v)
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

func pair(t *testing.T, base string, mac, phone *device) {
	t.Helper()
	session := uuid.NewString()
	if res, body := post(t, base+"/v1/pairing-sessions", mac.token, map[string]string{"session_id": session}); res.StatusCode != 201 {
		t.Fatalf("pairing-session %d %v", res.StatusCode, body)
	}
	if res, body := post(t, base+"/v1/pairings", phone.token, map[string]string{"session_id": session}); res.StatusCode != 201 {
		t.Fatalf("pairing %d %v", res.StatusCode, body)
	}
}

func dial(t *testing.T, base string, d *device) *websocket.Conn {
	t.Helper()
	h := http.Header{"Authorization": {"Bearer " + d.token}}
	c, res, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(base, "http")+"/v1/ws", h)
	if err != nil {
		t.Fatalf("dial: %v (%v)", err, res)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func envelope(from, to string, wake bool, n int) []byte {
	b, _ := json.Marshal(map[string]any{"envelope": map[string]any{
		"message_id": fmt.Sprintf("m-%d", n), "sender_device_id": from, "target_device_id": to,
		"nonce": "AAAAAAAAAAAAAAAA", "ciphertext": "Y2lwaGVydGV4dA==" + strings.Repeat("=", 0), "server_timestamp_ms": 0,
		"requires_wakeup": wake,
	}})
	return b
}

func read(t *testing.T, c *websocket.Conn, within time.Duration) (map[string]map[string]any, bool) {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(within))
	_, data, err := c.ReadMessage()
	if err != nil {
		return nil, false
	}
	var f map[string]map[string]any
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return f, true
}

// ---------------------------------------------------------------- tests

func TestRegisterRequiresProofOfPossession(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	priv, pub := keypair()
	id := uuid.NewString()
	_, ch := post(t, srv.URL+"/v1/devices/challenge", "", map[string]any{"device_id": id, "platform": "MACOS", "public_key": pub})

	// An attacker who only knows the public key cannot answer: wrong key → 401.
	otherPriv, _ := keypair()
	shared, _ := curve25519.X25519(otherPriv, b64(t, ch["server_public_key"]))
	res, _ := post(t, srv.URL+"/v1/devices/register", "", map[string]any{"challenge_id": ch["challenge_id"], "proof": auth.Proof(shared, id, b64(t, ch["nonce"]))})
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("forged proof accepted: %d", res.StatusCode)
	}
	// Challenges are single-use: the real device must ask again.
	d := register(t, srv.URL, auth.MacOS, &device{id: id, priv: priv, pub: pub})
	if d.token == "" {
		t.Fatal("no token")
	}
	// Re-registering the same device_id with a different key is refused.
	p2, pub2 := keypair()
	_, ch2 := post(t, srv.URL+"/v1/devices/challenge", "", map[string]any{"device_id": id, "platform": "MACOS", "public_key": pub2})
	sh2, _ := curve25519.X25519(p2, b64(t, ch2["server_public_key"]))
	res, _ = post(t, srv.URL+"/v1/devices/register", "", map[string]any{"challenge_id": ch2["challenge_id"], "proof": auth.Proof(sh2, id, b64(t, ch2["nonce"]))})
	if res.StatusCode != http.StatusConflict {
		t.Fatalf("key takeover not refused: %d", res.StatusCode)
	}
}

func TestPairingSessionIsSingleUseAndRolesEnforced(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	mac := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	session := uuid.NewString()
	if res, _ := post(t, srv.URL+"/v1/pairing-sessions", phone.token, map[string]string{"session_id": session}); res.StatusCode != 400 {
		t.Fatalf("phone opened a pairing session: %d", res.StatusCode)
	}
	post(t, srv.URL+"/v1/pairing-sessions", mac.token, map[string]string{"session_id": session})
	if res, _ := post(t, srv.URL+"/v1/pairings", phone.token, map[string]string{"session_id": session}); res.StatusCode != 201 {
		t.Fatalf("pair failed %d", res.StatusCode)
	}
	if res, _ := post(t, srv.URL+"/v1/pairings", phone.token, map[string]string{"session_id": session}); res.StatusCode != 404 {
		t.Fatalf("session reused: %d", res.StatusCode)
	}
}

func TestPairAckRoutedToMacAndEnvelopesBothWays(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	mac := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	pair(t, srv.URL, mac, phone)
	mc, pc := dial(t, srv.URL, mac), dial(t, srv.URL, phone)
	time.Sleep(50 * time.Millisecond)

	ack, _ := json.Marshal(map[string]any{"pair_ack": map[string]any{"session_id": "s", "android_device_id": phone.id,
		"android_pub_key": "cHVi", "nonce": "bm9uY2U=", "ciphertext": "Y3Q="}})
	_ = pc.WriteMessage(websocket.TextMessage, ack)
	if f, ok := read(t, mc, 2*time.Second); !ok || f["pair_ack"]["android_device_id"] != phone.id {
		t.Fatalf("mac did not receive pair_ack: %v", f)
	}

	_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phone.id, true, 1))
	f, ok := read(t, pc, 2*time.Second)
	if !ok {
		t.Fatal("phone did not receive envelope")
	}
	e := f["envelope"]
	if e["ciphertext"] != "Y2lwaGVydGV4dA==" || e["sender_device_id"] != mac.id {
		t.Fatalf("envelope altered: %v", e)
	}
	if ts, _ := e["server_timestamp_ms"].(float64); ts == 0 {
		t.Fatal("server_timestamp_ms not stamped")
	}
	_ = pc.WriteMessage(websocket.BinaryMessage, envelope(phone.id, mac.id, false, 2))
	if _, ok := read(t, mc, 2*time.Second); !ok {
		t.Fatal("mac did not receive reply")
	}
}

func TestRejectsSpoofedSenderAndUnpairedTarget(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	mac := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	stranger := register(t, srv.URL, auth.MacOS, nil)
	pair(t, srv.URL, mac, phone)
	pc, sc := dial(t, srv.URL, phone), dial(t, srv.URL, stranger)
	time.Sleep(50 * time.Millisecond)

	_ = sc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phone.id, false, 1))    // spoofed sender
	_ = sc.WriteMessage(websocket.BinaryMessage, envelope(stranger.id, phone.id, false, 2)) // not paired
	if f, ok := read(t, pc, 600*time.Millisecond); ok {
		t.Fatalf("phone received a forbidden frame: %v", f)
	}
}

func TestOfflineQueueDrainsFIFOAndWakesAndroid(t *testing.T) {
	store := db.NewMemory()
	waker := &fakeWaker{}
	srv := newServer(t, store, queue.NewMemory(time.Hour, 500), waker)
	mac := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	pair(t, srv.URL, mac, phone)
	if res, _ := post(t, srv.URL+"/v1/devices/fcm", phone.token, map[string]string{"fcm_token": "fcm-abc"}); res.StatusCode != 204 {
		t.Fatalf("fcm token %d", res.StatusCode)
	}
	mc := dial(t, srv.URL, mac)
	for i := 1; i <= 5; i++ {
		_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phone.id, true, i))
	}
	time.Sleep(200 * time.Millisecond)
	if waker.count() != 1 { // throttled: one wake-up per 10s burst
		t.Fatalf("expected 1 wake-up, got %d", waker.count())
	}
	pc := dial(t, srv.URL, phone)
	for i := 1; i <= 5; i++ {
		f, ok := read(t, pc, 2*time.Second)
		if !ok {
			t.Fatalf("missing queued frame %d", i)
		}
		if id := f["envelope"]["message_id"]; id != fmt.Sprintf("m-%d", i) {
			t.Fatalf("FIFO violated: got %v want m-%d", id, i)
		}
	}
}

func TestRateLimitPerDevice(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	mac := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	pair(t, srv.URL, mac, phone)
	mc, pc := dial(t, srv.URL, mac), dial(t, srv.URL, phone)
	time.Sleep(50 * time.Millisecond)
	for i := 0; i < 40; i++ {
		_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phone.id, false, i))
	}
	got := 0
	for {
		if _, ok := read(t, pc, 400*time.Millisecond); !ok {
			break
		}
		got++
	}
	if got < 20 || got > 22 { // burst 20 (+ refill during the test)
		t.Fatalf("rate limit: delivered %d of 40", got)
	}
}

func TestCrossInstanceRoutingViaRedis(t *testing.T) {
	mr := miniredis.RunT(t)
	store := db.NewMemory() // shared DB, two relay instances, one Redis
	b1, err := queue.NewRedis("redis://"+mr.Addr(), time.Hour, 500)
	if err != nil {
		t.Fatal(err)
	}
	b2, _ := queue.NewRedis("redis://"+mr.Addr(), time.Hour, 500)
	s1 := newServer(t, store, b1, &fakeWaker{})
	s2 := newServer(t, store, b2, &fakeWaker{})
	mac := register(t, s1.URL, auth.MacOS, nil)
	phone := register(t, s2.URL, auth.Android, nil)
	pair(t, s1.URL, mac, phone)

	mc, pc := dial(t, s1.URL, mac), dial(t, s2.URL, phone)
	time.Sleep(100 * time.Millisecond)
	_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phone.id, false, 1))
	if _, ok := read(t, pc, 2*time.Second); !ok {
		t.Fatal("cross-instance delivery failed")
	}
	// Phone goes away → Mac's frame lands in the shared Redis offline queue → drained on reconnect to the other instance.
	pc.Close()
	time.Sleep(150 * time.Millisecond)
	_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phone.id, false, 2))
	time.Sleep(150 * time.Millisecond)
	pc2 := dial(t, s1.URL, phone)
	if f, ok := read(t, pc2, 2*time.Second); !ok || f["envelope"]["message_id"] != "m-2" {
		t.Fatalf("offline frame not drained across instances: %v", f)
	}
}

func TestWebSocketRequiresToken(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	_, res, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/v1/ws", nil)
	if err == nil || res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated socket accepted")
	}
}

func get(t *testing.T, url, token string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	return res.StatusCode
}

func TestTokenInQueryStringIsRejected(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	d := register(t, srv.URL, auth.Android, nil)
	// A valid token in the URL must not authenticate: URLs end up in proxy and access logs.
	if code := get(t, srv.URL+"/v1/ws?token="+d.token, ""); code != http.StatusUnauthorized {
		t.Fatalf("query token accepted: %d", code)
	}
}

func TestRegistrationEndpointsAreRateLimited(t *testing.T) {
	srv := newServerOpts(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{}, api.Options{RegisterPerMin: 10, TokenTTL: time.Hour})
	priv, pub := keypair()
	_ = priv
	limited := 0
	for i := 0; i < 40; i++ {
		res, _ := post(t, srv.URL+"/v1/devices/challenge", "", map[string]any{"device_id": uuid.NewString(), "platform": auth.Android, "public_key": pub})
		if res.StatusCode == http.StatusTooManyRequests {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("no request was rate limited")
	}
}

func TestPairingSessionCannotBeHijackedByAnotherMac(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	macA := register(t, srv.URL, auth.MacOS, nil)
	macB := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	session := uuid.NewString()
	if res, _ := post(t, srv.URL+"/v1/pairing-sessions", macA.token, map[string]string{"session_id": session}); res.StatusCode != 201 {
		t.Fatalf("first announce %d", res.StatusCode)
	}
	if res, _ := post(t, srv.URL+"/v1/pairing-sessions", macB.token, map[string]string{"session_id": session}); res.StatusCode != http.StatusConflict {
		t.Fatalf("second Mac replaced the session: %d", res.StatusCode)
	}
	// The owner may re-announce (reconnect) without error.
	if res, _ := post(t, srv.URL+"/v1/pairing-sessions", macA.token, map[string]string{"session_id": session}); res.StatusCode != 201 {
		t.Fatalf("owner re-announce %d", res.StatusCode)
	}
	res, body := post(t, srv.URL+"/v1/pairings", phone.token, map[string]string{"session_id": session})
	if res.StatusCode != 201 || body["macos_device_id"] != macA.id {
		t.Fatalf("phone paired with the wrong Mac: %v", body)
	}
	if res, _ := post(t, srv.URL+"/v1/pairing-sessions", macA.token, map[string]string{"session_id": "short"}); res.StatusCode != 400 {
		t.Fatalf("short session id accepted: %d", res.StatusCode)
	}
}

func TestUnpairRevokesTokensAndClosesSockets(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	mac := register(t, srv.URL, auth.MacOS, nil)
	phone := register(t, srv.URL, auth.Android, nil)
	pair(t, srv.URL, mac, phone)
	pc := dial(t, srv.URL, phone)

	// iat has millisecond precision; make sure the old token is strictly older than the revocation.
	time.Sleep(5 * time.Millisecond)
	req, _ := http.NewRequest(http.MethodDelete, srv.URL+"/v1/pairings/"+mac.id, nil)
	req.Header.Set("Authorization", "Bearer "+phone.token)
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("unpair: %v %v", err, res)
	}
	if code := get(t, srv.URL+"/v1/ws", phone.token); code != http.StatusUnauthorized {
		t.Fatalf("revoked token still accepted: %d", code)
	}
	if _, ok := read(t, pc, time.Second); ok {
		t.Fatal("socket stayed open after unpair")
	}
	// Proving key possession again yields a working token.
	time.Sleep(5 * time.Millisecond)
	fresh := register(t, srv.URL, auth.Android, phone)
	if fresh.token == "" {
		t.Fatal("re-registration failed")
	}
}

// One Mac, two phones: each pair_ack reaches the Mac, envelopes route to the right phone in both directions,
// and the phones cannot talk to each other.
func TestOneMacPairsWithTwoPhones(t *testing.T) {
	srv := newServer(t, db.NewMemory(), queue.NewMemory(time.Hour, 500), &fakeWaker{})
	mac := register(t, srv.URL, auth.MacOS, nil)
	phoneA := register(t, srv.URL, auth.Android, nil)
	phoneB := register(t, srv.URL, auth.Android, nil)
	pair(t, srv.URL, mac, phoneA)
	pair(t, srv.URL, mac, phoneB)
	mc, ac, bc := dial(t, srv.URL, mac), dial(t, srv.URL, phoneA), dial(t, srv.URL, phoneB)
	time.Sleep(50 * time.Millisecond)

	// Each phone's pair_ack is routed to the Mac it just paired with.
	for _, p := range []*device{phoneA, phoneB} {
		conn := ac
		if p == phoneB {
			conn = bc
		}
		ack, _ := json.Marshal(map[string]any{"pair_ack": map[string]any{"session_id": "s", "android_device_id": p.id,
			"android_pub_key": "cHVi", "nonce": "bm9uY2U=", "ciphertext": "Y3Q="}})
		_ = conn.WriteMessage(websocket.TextMessage, ack)
		if f, ok := read(t, mc, 2*time.Second); !ok || f["pair_ack"]["android_device_id"] != p.id {
			t.Fatalf("mac did not receive pair_ack from %s: %v", p.id[:6], f)
		}
	}

	// Mac → each phone reaches only that phone.
	_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phoneA.id, false, 1))
	if f, ok := read(t, ac, 2*time.Second); !ok || f["envelope"]["target_device_id"] != phoneA.id {
		t.Fatalf("phone A did not get its envelope: %v", f)
	}
	// (A timed-out read would poison the socket, so "B got nothing of A's" is checked by B's first frame below.)
	_ = mc.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phoneB.id, false, 2))
	if f, ok := read(t, bc, 2*time.Second); !ok || f["envelope"]["target_device_id"] != phoneB.id || f["envelope"]["message_id"] != "m-2" {
		t.Fatalf("phone B's first frame was not its own envelope (leak from phone A?): %v", f)
	}

	// Each phone → Mac carries its own sender id, so the Mac can pick the right session keys.
	_ = ac.WriteMessage(websocket.BinaryMessage, envelope(phoneA.id, mac.id, false, 3))
	if f, ok := read(t, mc, 2*time.Second); !ok || f["envelope"]["sender_device_id"] != phoneA.id {
		t.Fatalf("mac did not get phone A's envelope: %v", f)
	}
	_ = bc.WriteMessage(websocket.BinaryMessage, envelope(phoneB.id, mac.id, false, 4))
	if f, ok := read(t, mc, 2*time.Second); !ok || f["envelope"]["sender_device_id"] != phoneB.id {
		t.Fatalf("mac did not get phone B's envelope: %v", f)
	}

	// Phones are not paired with each other.
	_ = ac.WriteMessage(websocket.BinaryMessage, envelope(phoneA.id, phoneB.id, false, 5))
	if f, ok := read(t, bc, 500*time.Millisecond); ok {
		t.Fatalf("phone A reached phone B: %v", f)
	}

	// Unpairing one phone leaves the other working.
	time.Sleep(5 * time.Millisecond)
	req, _ := http.NewRequest(http.MethodDelete, srv.URL+"/v1/pairings/"+phoneA.id, nil)
	req.Header.Set("Authorization", "Bearer "+mac.token)
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != http.StatusNoContent {
		t.Fatalf("unpair A: %v %v", err, res)
	}
	mac2 := register(t, srv.URL, auth.MacOS, mac) // the Mac's token was revoked; it proves key possession again
	mc2, bc2 := dial(t, srv.URL, mac2), dial(t, srv.URL, registerAgain(t, srv.URL, phoneB))
	time.Sleep(50 * time.Millisecond)
	_ = mc2.WriteMessage(websocket.BinaryMessage, envelope(mac.id, phoneB.id, false, 6))
	if f, ok := read(t, bc2, 2*time.Second); !ok || f["envelope"]["target_device_id"] != phoneB.id {
		t.Fatalf("phone B stopped working after unpairing phone A: %v", f)
	}
}

// registerAgain re-proves key possession for a device whose token was revoked.
func registerAgain(t *testing.T, base string, d *device) *device {
	t.Helper()
	time.Sleep(5 * time.Millisecond)
	return register(t, base, auth.Android, d)
}
