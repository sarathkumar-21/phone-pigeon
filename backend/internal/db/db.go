// Package db persists device identities and pairings — never message content (spec §9.1).
package db

import (
	"context"
	"embed"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

var (
	ErrNotFound   = errors.New("not found")
	ErrKeyChanged = errors.New("device already registered with a different public key")
)

type Device struct {
	ID         string
	Platform   string
	PublicKey  []byte
	FCMToken   string
	CreatedAt  time.Time
	LastSeenAt time.Time
}

type Pairing struct {
	ID        string
	AndroidID string
	MacID     string
	CreatedAt time.Time
}

type Store interface {
	// UpsertDevice registers a device. Re-registration must present the same public key.
	UpsertDevice(ctx context.Context, d Device) error
	GetDevice(ctx context.Context, id string) (Device, error)
	SetFCMToken(ctx context.Context, id, token string) error
	Touch(ctx context.Context, id string) error
	CreatePairing(ctx context.Context, androidID, macID string) (Pairing, error)
	DeletePairing(ctx context.Context, a, b string) error
	ArePaired(ctx context.Context, a, b string) (bool, error)
	// LatestMacFor returns the Mac most recently paired with an Android device.
	LatestMacFor(ctx context.Context, androidID string) (string, error)
	Close()
}

// ---------------------------------------------------------------- PostgreSQL

type Postgres struct{ pool *pgxpool.Pool }

func OpenPostgres(ctx context.Context, url string) (*Postgres, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	p := &Postgres{pool: pool}
	return p, p.migrate(ctx)
}

func (p *Postgres) migrate(ctx context.Context) error {
	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, e := range entries {
		sql, err := migrations.ReadFile("migrations/" + e.Name())
		if err != nil {
			return err
		}
		if _, err := p.pool.Exec(ctx, string(sql)); err != nil {
			return err
		}
	}
	return nil
}

func (p *Postgres) Close() { p.pool.Close() }

func (p *Postgres) UpsertDevice(ctx context.Context, d Device) error {
	var existing []byte
	err := p.pool.QueryRow(ctx, `SELECT public_key FROM devices WHERE device_id = $1`, d.ID).Scan(&existing)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		_, err = p.pool.Exec(ctx, `INSERT INTO devices (device_id, platform, public_key) VALUES ($1, $2, $3)`, d.ID, d.Platform, d.PublicKey)
		return err
	case err != nil:
		return err
	case string(existing) != string(d.PublicKey):
		return ErrKeyChanged
	default:
		_, err = p.pool.Exec(ctx, `UPDATE devices SET last_seen_at = NOW() WHERE device_id = $1`, d.ID)
		return err
	}
}

func (p *Postgres) GetDevice(ctx context.Context, id string) (Device, error) {
	var d Device
	var fcm *string
	err := p.pool.QueryRow(ctx, `SELECT device_id, platform, public_key, fcm_token, created_at, last_seen_at FROM devices WHERE device_id = $1`, id).
		Scan(&d.ID, &d.Platform, &d.PublicKey, &fcm, &d.CreatedAt, &d.LastSeenAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return d, ErrNotFound
	}
	if fcm != nil {
		d.FCMToken = *fcm
	}
	return d, err
}

func (p *Postgres) SetFCMToken(ctx context.Context, id, token string) error {
	_, err := p.pool.Exec(ctx, `UPDATE devices SET fcm_token = $2 WHERE device_id = $1`, id, token)
	return err
}

func (p *Postgres) Touch(ctx context.Context, id string) error {
	_, err := p.pool.Exec(ctx, `UPDATE devices SET last_seen_at = NOW() WHERE device_id = $1`, id)
	return err
}

func (p *Postgres) CreatePairing(ctx context.Context, androidID, macID string) (Pairing, error) {
	pr := Pairing{ID: uuid.NewString(), AndroidID: androidID, MacID: macID}
	err := p.pool.QueryRow(ctx, `
		INSERT INTO pairings (pairing_id, android_device_id, macos_device_id) VALUES ($1, $2, $3)
		ON CONFLICT (android_device_id, macos_device_id) DO UPDATE SET created_at = NOW()
		RETURNING pairing_id, created_at`, pr.ID, androidID, macID).Scan(&pr.ID, &pr.CreatedAt)
	return pr, err
}

func (p *Postgres) DeletePairing(ctx context.Context, a, b string) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM pairings WHERE (android_device_id = $1 AND macos_device_id = $2) OR (android_device_id = $2 AND macos_device_id = $1)`, a, b)
	return err
}

func (p *Postgres) ArePaired(ctx context.Context, a, b string) (bool, error) {
	var ok bool
	err := p.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pairings WHERE (android_device_id = $1 AND macos_device_id = $2) OR (android_device_id = $2 AND macos_device_id = $1))`, a, b).Scan(&ok)
	return ok, err
}

func (p *Postgres) LatestMacFor(ctx context.Context, androidID string) (string, error) {
	var mac string
	err := p.pool.QueryRow(ctx, `SELECT macos_device_id FROM pairings WHERE android_device_id = $1 ORDER BY created_at DESC LIMIT 1`, androidID).Scan(&mac)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return mac, err
}

// ---------------------------------------------------------------- in-memory (dev & tests)

type Memory struct {
	mu       sync.RWMutex
	devices  map[string]Device
	pairings []Pairing
}

func NewMemory() *Memory { return &Memory{devices: map[string]Device{}} }

func (m *Memory) Close() {}

func (m *Memory) UpsertDevice(_ context.Context, d Device) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if e, ok := m.devices[d.ID]; ok {
		if string(e.PublicKey) != string(d.PublicKey) {
			return ErrKeyChanged
		}
		e.LastSeenAt = time.Now()
		m.devices[d.ID] = e
		return nil
	}
	d.CreatedAt, d.LastSeenAt = time.Now(), time.Now()
	m.devices[d.ID] = d
	return nil
}

func (m *Memory) GetDevice(_ context.Context, id string) (Device, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	d, ok := m.devices[id]
	if !ok {
		return d, ErrNotFound
	}
	return d, nil
}

func (m *Memory) SetFCMToken(_ context.Context, id, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return ErrNotFound
	}
	d.FCMToken = token
	m.devices[id] = d
	return nil
}

func (m *Memory) Touch(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if d, ok := m.devices[id]; ok {
		d.LastSeenAt = time.Now()
		m.devices[id] = d
	}
	return nil
}

func (m *Memory) CreatePairing(_ context.Context, androidID, macID string) (Pairing, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, p := range m.pairings {
		if p.AndroidID == androidID && p.MacID == macID {
			m.pairings[i].CreatedAt = time.Now()
			return m.pairings[i], nil
		}
	}
	p := Pairing{ID: uuid.NewString(), AndroidID: androidID, MacID: macID, CreatedAt: time.Now()}
	m.pairings = append(m.pairings, p)
	return p, nil
}

func (m *Memory) DeletePairing(_ context.Context, a, b string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := m.pairings[:0]
	for _, p := range m.pairings {
		if !((p.AndroidID == a && p.MacID == b) || (p.AndroidID == b && p.MacID == a)) {
			out = append(out, p)
		}
	}
	m.pairings = out
	return nil
}

func (m *Memory) ArePaired(_ context.Context, a, b string) (bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, p := range m.pairings {
		if (p.AndroidID == a && p.MacID == b) || (p.AndroidID == b && p.MacID == a) {
			return true, nil
		}
	}
	return false, nil
}

func (m *Memory) LatestMacFor(_ context.Context, androidID string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var best *Pairing
	for i := range m.pairings {
		p := &m.pairings[i]
		if p.AndroidID == androidID && (best == nil || !p.CreatedAt.Before(best.CreatedAt)) {
			best = p
		}
	}
	if best == nil {
		return "", ErrNotFound
	}
	return best.MacID, nil
}
