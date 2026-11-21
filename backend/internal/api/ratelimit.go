package api

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// ipLimiter is a small per-client token bucket for the unauthenticated endpoints
// (challenge/register), which otherwise let anyone write state for free.
type ipLimiter struct {
	mu       sync.Mutex
	limit    rate.Limit
	burst    int
	entries  map[string]*ipEntry
	lastSwep time.Time
}

type ipEntry struct {
	lim  *rate.Limiter
	seen time.Time
}

func newIPLimiter(perMinute int) *ipLimiter {
	if perMinute <= 0 {
		return nil
	}
	burst := perMinute / 2
	if burst < 5 {
		burst = 5
	}
	return &ipLimiter{limit: rate.Limit(float64(perMinute) / 60), burst: burst, entries: map[string]*ipEntry{}}
}

func (l *ipLimiter) allow(ip string) bool {
	if l == nil {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	if now.Sub(l.lastSwep) > time.Minute {
		for k, e := range l.entries {
			if now.Sub(e.seen) > 10*time.Minute {
				delete(l.entries, k)
			}
		}
		l.lastSwep = now
	}
	e := l.entries[ip]
	if e == nil {
		if len(l.entries) >= 100_000 { // hard cap: refuse new sources rather than grow forever
			return false
		}
		e = &ipEntry{lim: rate.NewLimiter(l.limit, l.burst)}
		l.entries[ip] = e
	}
	e.seen = now
	return e.lim.Allow()
}

// clientIP returns the caller's address. Behind a trusted reverse proxy it takes the last
// X-Forwarded-For hop (the one the proxy itself appended), never the client-supplied first one.
func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
