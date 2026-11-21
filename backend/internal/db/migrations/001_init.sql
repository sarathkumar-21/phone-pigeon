-- Spec v2 §9.1 — device identity, public keys, pairing links and FCM tokens only. Zero user content.
CREATE TABLE IF NOT EXISTS devices (
    device_id UUID PRIMARY KEY,
    platform VARCHAR(16) NOT NULL CHECK (platform IN ('ANDROID', 'MACOS')),
    public_key BYTEA NOT NULL,
    fcm_token TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pairings (
    pairing_id UUID PRIMARY KEY,
    android_device_id UUID NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    macos_device_id UUID NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (android_device_id, macos_device_id)
);

CREATE INDEX IF NOT EXISTS idx_pairings_android_created ON pairings (android_device_id, created_at DESC);
