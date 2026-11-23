// Package metrics exports the Prometheus series named in spec §10.3.
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	ActiveConnections = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "active_ws_connections", Help: "Open device WebSocket connections on this instance."})
	EnvelopesRelayed = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "envelopes_relayed_total", Help: "Frames routed, by outcome."}, []string{"outcome"})
	FCMWakeups = promauto.NewCounter(prometheus.CounterOpts{
		Name: "fcm_wakeups_sent_total", Help: "High-priority FCM wake-ups sent to Android."})
	OfflineQueueDepth = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "offline_queue_depth", Help: "Frames waiting in offline queues (approximate, this instance's view)."})
	RateLimited = promauto.NewCounter(prometheus.CounterOpts{
		Name: "envelopes_rate_limited_total", Help: "Frames dropped by the per-device rate limiter."})
)
