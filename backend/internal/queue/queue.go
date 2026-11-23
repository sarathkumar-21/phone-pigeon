// Package queue implements cross-instance routing (Redis Pub/Sub), the 24h offline
// queue, presence and short-lived key/value state (challenges, pairing sessions).
package queue

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

var ErrNotFound = errors.New("not found")

type Broker interface {
	// Publish hands a frame to whichever instance holds the device's socket.
	// It reports false when no subscriber received it.
	Publish(ctx context.Context, deviceID string, frame []byte) (bool, error)
	Subscribe(ctx context.Context, deviceID string) (<-chan []byte, func(), error)
	// Enqueue appends to the device's offline queue (FIFO, capped, TTL) and returns its depth.
	Enqueue(ctx context.Context, deviceID string, frame []byte) (int64, error)
	// Drain returns and removes all queued frames in FIFO order.
	Drain(ctx context.Context, deviceID string) ([][]byte, error)
	SetPresence(ctx context.Context, deviceID, instance string, ttl time.Duration) error
	ClearPresence(ctx context.Context, deviceID, instance string) error
	Online(ctx context.Context, deviceID string) (bool, error)
	Put(ctx context.Context, key string, val []byte, ttl time.Duration) error
	// PutNX stores only when the key is absent; it reports whether it stored.
	PutNX(ctx context.Context, key string, val []byte, ttl time.Duration) (bool, error)
	// Get reads a key without removing it.
	Get(ctx context.Context, key string) ([]byte, error)
	// Take atomically reads and deletes a key (single-use challenges / sessions).
	Take(ctx context.Context, key string) ([]byte, error)
	// Allow returns true at most once per ttl for a key (wake-up throttling).
	Allow(ctx context.Context, key string, ttl time.Duration) (bool, error)
	Close() error
}

// ---------------------------------------------------------------- Redis

type Redis struct {
	c          *redis.Client
	offlineTTL time.Duration
	offlineCap int64
}

func NewRedis(url string, offlineTTL time.Duration, offlineCap int64) (*Redis, error) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		return nil, err
	}
	c := redis.NewClient(opt)
	if err := c.Ping(context.Background()).Err(); err != nil {
		return nil, err
	}
	return &Redis{c: c, offlineTTL: offlineTTL, offlineCap: offlineCap}, nil
}

func chanKey(id string) string     { return "device:" + id }
func offlineKey(id string) string  { return "offline:" + id }
func presenceKey(id string) string { return "presence:" + id }

func (r *Redis) Close() error { return r.c.Close() }

func (r *Redis) Publish(ctx context.Context, id string, frame []byte) (bool, error) {
	n, err := r.c.Publish(ctx, chanKey(id), frame).Result()
	return n > 0, err
}

func (r *Redis) Subscribe(ctx context.Context, id string) (<-chan []byte, func(), error) {
	sub := r.c.Subscribe(ctx, chanKey(id))
	if _, err := sub.Receive(ctx); err != nil { // wait for confirmation
		_ = sub.Close()
		return nil, nil, err
	}
	out := make(chan []byte, 256)
	go func() {
		defer close(out)
		for m := range sub.Channel() {
			out <- []byte(m.Payload)
		}
	}()
	return out, func() { _ = sub.Close() }, nil
}

func (r *Redis) Enqueue(ctx context.Context, id string, frame []byte) (int64, error) {
	k := offlineKey(id)
	pipe := r.c.TxPipeline()
	pipe.RPush(ctx, k, frame)
	pipe.LTrim(ctx, k, -r.offlineCap, -1) // keep the newest N
	pipe.Expire(ctx, k, r.offlineTTL)
	n := pipe.LLen(ctx, k)
	if _, err := pipe.Exec(ctx); err != nil {
		return 0, err
	}
	return n.Val(), nil
}

func (r *Redis) Drain(ctx context.Context, id string) ([][]byte, error) {
	k := offlineKey(id)
	pipe := r.c.TxPipeline()
	lr := pipe.LRange(ctx, k, 0, -1)
	pipe.Del(ctx, k)
	if _, err := pipe.Exec(ctx); err != nil {
		return nil, err
	}
	out := make([][]byte, 0, len(lr.Val()))
	for _, s := range lr.Val() {
		out = append(out, []byte(s))
	}
	return out, nil
}

func (r *Redis) SetPresence(ctx context.Context, id, inst string, ttl time.Duration) error {
	return r.c.Set(ctx, presenceKey(id), inst, ttl).Err()
}

var clearIfOwner = redis.NewScript(`if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) end return 0`)

func (r *Redis) ClearPresence(ctx context.Context, id, inst string) error {
	return clearIfOwner.Run(ctx, r.c, []string{presenceKey(id)}, inst).Err()
}

func (r *Redis) Online(ctx context.Context, id string) (bool, error) {
	n, err := r.c.Exists(ctx, presenceKey(id)).Result()
	return n > 0, err
}

func (r *Redis) Put(ctx context.Context, key string, val []byte, ttl time.Duration) error {
	return r.c.Set(ctx, "kv:"+key, val, ttl).Err()
}

func (r *Redis) PutNX(ctx context.Context, key string, val []byte, ttl time.Duration) (bool, error) {
	return r.c.SetNX(ctx, "kv:"+key, val, ttl).Result()
}

func (r *Redis) Get(ctx context.Context, key string) ([]byte, error) {
	v, err := r.c.Get(ctx, "kv:"+key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, ErrNotFound
	}
	return v, err
}

func (r *Redis) Take(ctx context.Context, key string) ([]byte, error) {
	v, err := r.c.GetDel(ctx, "kv:"+key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, ErrNotFound
	}
	return v, err
}

func (r *Redis) Allow(ctx context.Context, key string, ttl time.Duration) (bool, error) {
	return r.c.SetNX(ctx, "throttle:"+key, 1, ttl).Result()
}

// ---------------------------------------------------------------- in-memory (single instance)

type queued struct {
	at    time.Time
	frame []byte
}

type kv struct {
	val []byte
	exp time.Time
}

type Memory struct {
	mu         sync.Mutex
	subs       map[string]map[chan []byte]struct{}
	offline    map[string][]queued
	presence   map[string]kv
	store      map[string]kv
	offlineTTL time.Duration
	offlineCap int64
}

func NewMemory(offlineTTL time.Duration, offlineCap int64) *Memory {
	return &Memory{
		subs: map[string]map[chan []byte]struct{}{}, offline: map[string][]queued{},
		presence: map[string]kv{}, store: map[string]kv{}, offlineTTL: offlineTTL, offlineCap: offlineCap,
	}
}

func (m *Memory) Close() error { return nil }

func (m *Memory) Publish(_ context.Context, id string, frame []byte) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delivered := false
	for ch := range m.subs[id] {
		select {
		case ch <- frame:
			delivered = true
		default:
		}
	}
	return delivered, nil
}

func (m *Memory) Subscribe(_ context.Context, id string) (<-chan []byte, func(), error) {
	ch := make(chan []byte, 256)
	m.mu.Lock()
	if m.subs[id] == nil {
		m.subs[id] = map[chan []byte]struct{}{}
	}
	m.subs[id][ch] = struct{}{}
	m.mu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			m.mu.Lock()
			delete(m.subs[id], ch)
			m.mu.Unlock()
			close(ch)
		})
	}, nil
}

func (m *Memory) Enqueue(_ context.Context, id string, frame []byte) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	q := append(m.offline[id], queued{time.Now(), frame})
	if int64(len(q)) > m.offlineCap {
		q = q[int64(len(q))-m.offlineCap:]
	}
	m.offline[id] = q
	return int64(len(q)), nil
}

func (m *Memory) Drain(_ context.Context, id string) ([][]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cutoff := time.Now().Add(-m.offlineTTL)
	var out [][]byte
	for _, q := range m.offline[id] {
		if q.at.After(cutoff) {
			out = append(out, q.frame)
		}
	}
	delete(m.offline, id)
	return out, nil
}

func (m *Memory) SetPresence(_ context.Context, id, inst string, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.presence[id] = kv{[]byte(inst), time.Now().Add(ttl)}
	return nil
}

func (m *Memory) ClearPresence(_ context.Context, id, inst string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p, ok := m.presence[id]; ok && string(p.val) == inst {
		delete(m.presence, id)
	}
	return nil
}

func (m *Memory) Online(_ context.Context, id string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.presence[id]
	return ok && time.Now().Before(p.exp), nil
}

// sweepLocked drops expired entries once the map grows, so unauthenticated challenge floods cannot leak memory.
func (m *Memory) sweepLocked() {
	if len(m.store) < 4096 {
		return
	}
	now := time.Now()
	for k, v := range m.store {
		if now.After(v.exp) {
			delete(m.store, k)
		}
	}
}

func (m *Memory) Put(_ context.Context, key string, val []byte, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sweepLocked()
	m.store[key] = kv{val, time.Now().Add(ttl)}
	return nil
}

func (m *Memory) PutNX(_ context.Context, key string, val []byte, ttl time.Duration) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if v, ok := m.store[key]; ok && time.Now().Before(v.exp) {
		return false, nil
	}
	m.store[key] = kv{val, time.Now().Add(ttl)}
	return true, nil
}

func (m *Memory) Get(_ context.Context, key string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.store[key]
	if !ok || time.Now().After(v.exp) {
		return nil, ErrNotFound
	}
	return v.val, nil
}

func (m *Memory) Take(_ context.Context, key string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.store[key]
	delete(m.store, key)
	if !ok || time.Now().After(v.exp) {
		return nil, ErrNotFound
	}
	return v.val, nil
}

func (m *Memory) Allow(_ context.Context, key string, ttl time.Duration) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := "throttle:" + key
	if v, ok := m.store[k]; ok && time.Now().Before(v.exp) {
		return false, nil
	}
	m.store[k] = kv{nil, time.Now().Add(ttl)}
	return true, nil
}
