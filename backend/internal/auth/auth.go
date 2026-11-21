// Package auth issues device JWTs and verifies X25519 proof-of-possession.
//
// Registration is a two-step challenge so that knowing a device's *public* key is
// not enough to obtain a token for it:
//
//  1. POST /v1/devices/challenge → server returns an ephemeral X25519 public key + nonce.
//  2. Device computes S = X25519(device_priv, server_eph_pub) and sends
//     proof = HMAC-SHA256(S, "phonepigeon-register-v1" ‖ device_id ‖ nonce).
//     The server recomputes S = X25519(server_eph_priv, device_pub) and compares.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"golang.org/x/crypto/curve25519"
)

func init() {
	// Millisecond `iat` lets "revoke everything issued before now" work without a one-second blind spot.
	jwt.TimePrecision = time.Millisecond
}

// MinSecretBytes is the shortest JWT signing secret the relay accepts.
const MinSecretBytes = 32

const ProofContext = "phonepigeon-register-v1"

type Platform string

const (
	Android Platform = "ANDROID"
	MacOS   Platform = "MACOS"
)

func (p Platform) Valid() bool { return p == Android || p == MacOS }

// Challenge is held server-side (ephemeral store) until the device answers it.
type Challenge struct {
	DeviceID   string   `json:"device_id"`
	Platform   Platform `json:"platform"`
	PublicKey  []byte   `json:"public_key"`
	ServerPriv []byte   `json:"server_priv"`
	Nonce      []byte   `json:"nonce"`
}

// NewChallenge creates an ephemeral server keypair and nonce.
func NewChallenge(deviceID string, platform Platform, publicKey []byte) (Challenge, []byte, error) {
	if len(publicKey) != curve25519.PointSize {
		return Challenge{}, nil, errors.New("public_key must be 32 bytes")
	}
	priv := make([]byte, curve25519.ScalarSize)
	nonce := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return Challenge{}, nil, err
	}
	if _, err := rand.Read(nonce); err != nil {
		return Challenge{}, nil, err
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return Challenge{}, nil, err
	}
	return Challenge{DeviceID: deviceID, Platform: platform, PublicKey: publicKey, ServerPriv: priv, Nonce: nonce}, pub, nil
}

// ExpectedProof returns the HMAC a holder of the device private key will produce.
func (c Challenge) ExpectedProof() ([]byte, error) {
	shared, err := curve25519.X25519(c.ServerPriv, c.PublicKey)
	if err != nil {
		return nil, err
	}
	return Proof(shared, c.DeviceID, c.Nonce), nil
}

// Proof is the client-side computation, exported for tests and tooling.
func Proof(shared []byte, deviceID string, nonce []byte) []byte {
	m := hmac.New(sha256.New, shared)
	m.Write([]byte(ProofContext))
	m.Write([]byte(deviceID))
	m.Write(nonce)
	return m.Sum(nil)
}

func (c Challenge) Verify(proof []byte) bool {
	want, err := c.ExpectedProof()
	return err == nil && hmac.Equal(want, proof)
}

// ---------------------------------------------------------------- JWT

type Claims struct {
	Platform Platform `json:"plt"`
	jwt.RegisteredClaims
}

type Issuer struct {
	secret []byte
	ttl    time.Duration
}

func NewIssuer(secret []byte, ttl time.Duration) *Issuer { return &Issuer{secret: secret, ttl: ttl} }

func (i *Issuer) Issue(deviceID string, p Platform) (string, time.Time, error) {
	exp := time.Now().Add(i.ttl)
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, Claims{
		Platform: p,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   deviceID,
			ID:        uuid.NewString(),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(exp),
			Issuer:    "phonepigeon-relay",
		},
	})
	s, err := tok.SignedString(i.secret)
	return s, exp, err
}

func (i *Issuer) Verify(token string) (*Claims, error) {
	c := &Claims{}
	_, err := jwt.ParseWithClaims(token, c, func(t *jwt.Token) (any, error) {
		if t.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected alg %v", t.Header["alg"])
		}
		return i.secret, nil
	}, jwt.WithIssuer("phonepigeon-relay"), jwt.WithExpirationRequired())
	if err != nil {
		return nil, err
	}
	if c.Subject == "" || !c.Platform.Valid() {
		return nil, errors.New("invalid claims")
	}
	return c, nil
}
