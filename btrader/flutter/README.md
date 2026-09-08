# B-Trader — Flutter apps

One Flutter codebase for both client-facing surfaces, sharing `btrader_core`.

```
flutter/
├── packages/btrader_core/   shared: models, API (Dio), WebSocket, Riverpod state, Material 3 theme
├── apps/trader/             mobile trader app (iOS + Android)
└── apps/admin/              web admin dashboard (Flutter web)
```

Stack: **Riverpod** (state), **go_router** (navigation), **Dio** (HTTP + JWT refresh),
**web_socket_channel** (live feed). Material 3 with light **and** dark themes, brand
color injected per tenant.

## Run

```bash
dart pub global activate melos
melos bootstrap                      # resolves all packages with local path overrides

# Trader app (device/emulator)
cd apps/trader && flutter run \
  --dart-define=API_BASE=http://localhost:4100 \
  --dart-define=WS_URL=ws://localhost:4101 \
  --dart-define=TENANT=demo

# Admin (web)
cd apps/admin && flutter run -d chrome \
  --dart-define=API_BASE=http://localhost:4100 \
  --dart-define=WS_URL=ws://localhost:4101
```

Talks to the existing B-Trader gateway API (`/v1`). Sign in with the seeded
`trader@demofx.com / Trader123!` (trader) or an admin account.
