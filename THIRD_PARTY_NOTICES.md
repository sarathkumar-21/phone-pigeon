# Third-party notices

PhonePigeon itself is [MIT licensed](LICENSE). It builds on the open-source components below. Each keeps its own license; follow the links for the full texts. Transitive dependencies (for example the Google Cloud client libraries that Firebase Admin pulls into the relay) are listed in `backend/go.sum` and the Gradle dependency graph (`./gradlew :app:dependencies`).

The Mac app uses only Apple system frameworks and has no third-party packages.

## Android app

| Component | License |
| --- | --- |
| AndroidX (Compose UI, Material 3, Activity, Core, Lifecycle) | Apache-2.0 |
| Kotlin standard library, kotlinx.coroutines, kotlinx.serialization | Apache-2.0 |
| OkHttp (Square) | Apache-2.0 |
| Tink for Android (Google) | Apache-2.0 |

## Relay (Go)

| Component | License |
| --- | --- |
| firebase.google.com/go/v4 and google.golang.org/api | Apache-2.0 / BSD-3-Clause |
| github.com/golang-jwt/jwt | MIT |
| github.com/google/uuid | BSD-3-Clause |
| github.com/gorilla/websocket | BSD-2-Clause |
| github.com/jackc/pgx | MIT |
| github.com/prometheus/client_golang | Apache-2.0 |
| github.com/redis/go-redis | BSD-2-Clause |
| github.com/alicebob/miniredis (tests only) | MIT |
| golang.org/x/crypto, golang.org/x/time | BSD-3-Clause |

## Deployment images (not bundled; pulled by Docker Compose)

| Component | License |
| --- | --- |
| Caddy | Apache-2.0 |
| coturn | BSD-3-Clause |
| PostgreSQL | PostgreSQL License |
| Redis | See the license of the image tag you choose |

## Trademarks

Android and Google are trademarks of Google LLC. macOS and Apple are trademarks of Apple Inc. All other names belong to their owners. PhonePigeon is not affiliated with or endorsed by them.
