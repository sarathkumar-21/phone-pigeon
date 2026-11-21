// Package fcm wakes a dozing Android phone with a high-priority data message (spec §2, §10.2).
package fcm

import (
	"time"
	"context"
	"log/slog"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"google.golang.org/api/option"
)

type Waker interface {
	Wake(ctx context.Context, fcmToken string) error
}

// Noop is used when no Firebase credentials are configured.
type Noop struct{}

func (Noop) Wake(context.Context, string) error { return nil }

type Firebase struct{ client *messaging.Client }

func NewFirebase(ctx context.Context, credentialsFile string) (*Firebase, error) {
	app, err := firebase.NewApp(ctx, nil, option.WithCredentialsFile(credentialsFile))
	if err != nil {
		return nil, err
	}
	c, err := app.Messaging(ctx)
	if err != nil {
		return nil, err
	}
	return &Firebase{client: c}, nil
}

// Wake sends {"type":"WAKEUP"} — no content, just a nudge to reconnect and drain the queue.
func (f *Firebase) Wake(ctx context.Context, token string) error {
	_, err := f.client.Send(ctx, &messaging.Message{
		Token:   token,
		Data:    map[string]string{"type": "WAKEUP"},
		Android: &messaging.AndroidConfig{Priority: "high", TTL: ptr(time.Minute)},
	})
	if err != nil {
		slog.Warn("fcm wake failed", "err", err)
	}
	return err
}

func ptr[T any](v T) *T { return &v }
