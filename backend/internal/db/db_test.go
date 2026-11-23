package db

import (
	"context"
	"os"
	"testing"

	"github.com/google/uuid"
)

// Runs against PostgreSQL when PHONEPIGEON_TEST_PG is set (e.g. postgres://localhost:54329/postgres?sslmode=disable),
// and always against the in-memory store, so both implementations satisfy the same contract.
func stores(t *testing.T) map[string]Store {
	out := map[string]Store{"memory": NewMemory()}
	if url := os.Getenv("PHONEPIGEON_TEST_PG"); url != "" {
		pg, err := OpenPostgres(context.Background(), url)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(pg.Close)
		out["postgres"] = pg
	}
	return out
}

func TestStoreContract(t *testing.T) {
	for name, s := range stores(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			mac, phone, mac2 := uuid.NewString(), uuid.NewString(), uuid.NewString()
			must(t, s.UpsertDevice(ctx, Device{ID: mac, Platform: "MACOS", PublicKey: []byte("k1")}))
			must(t, s.UpsertDevice(ctx, Device{ID: mac2, Platform: "MACOS", PublicKey: []byte("k3")}))
			must(t, s.UpsertDevice(ctx, Device{ID: phone, Platform: "ANDROID", PublicKey: []byte("k2")}))
			must(t, s.UpsertDevice(ctx, Device{ID: mac, Platform: "MACOS", PublicKey: []byte("k1")})) // idempotent
			if err := s.UpsertDevice(ctx, Device{ID: mac, Platform: "MACOS", PublicKey: []byte("evil")}); err != ErrKeyChanged {
				t.Fatalf("key change: %v", err)
			}
			must(t, s.SetFCMToken(ctx, phone, "tok"))
			if d, _ := s.GetDevice(ctx, phone); d.FCMToken != "tok" {
				t.Fatal("fcm token not stored")
			}
			if ok, _ := s.ArePaired(ctx, mac, phone); ok {
				t.Fatal("paired before pairing")
			}
			_, err := s.CreatePairing(ctx, phone, mac)
			must(t, err)
			_, err = s.CreatePairing(ctx, phone, mac2)
			must(t, err)
			if ok, _ := s.ArePaired(ctx, mac, phone); !ok {
				t.Fatal("pairing not visible (mac→phone)")
			}
			if m, _ := s.LatestMacFor(ctx, phone); m != mac2 {
				t.Fatalf("latest mac = %s want %s", m, mac2)
			}
			must(t, s.DeletePairing(ctx, mac2, phone))
			if m, _ := s.LatestMacFor(ctx, phone); m != mac {
				t.Fatalf("after unpair latest mac = %s", m)
			}
		})
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
