# B-Trader — Flutter apps

Flutter admin dashboard, sharing `btrader_core`. The live client portal is the
static Trade+ bundle in `web/portal` (Home, Quotes, Chart, Trade, History) — not
a rebuild of a Markets/Portfolio/Settings trader app.

```
flutter/
├── packages/btrader_core/   shared: models, API (Dio), WebSocket, Riverpod state, Material 3 theme
├── apps/admin/              web admin dashboard (Flutter web)
└── apps/portal/             Android APK for the live Trade+ portal (Home/Quotes/Chart/Trade/History)
```

Stack: **Riverpod** (state), **go_router** (navigation), **Dio** (HTTP + JWT refresh),
**web_socket_channel** (live feed). Material 3 with light **and** dark themes, brand
color injected per tenant.

## Run

```bash
dart pub global activate melos
melos bootstrap                      # resolves all packages with local path overrides

# Admin (web)
cd apps/admin && flutter run -d chrome \
  --dart-define=API_BASE=http://localhost:4100 \
  --dart-define=WS_URL=ws://localhost:4101
```

Talks to the existing B-Trader gateway API (`/v1`). Sign in with a
TENANT_ADMIN / SUPER_ADMIN account.
