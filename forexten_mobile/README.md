# Burjex Prime — `forexten_mobile`

New Flutter rewrite of the live Trade+ portal at https://portal.burjexprime.net.

This is **not** recovered original Dart (that source was never on GitHub). It is **not** the deleted Markets / Portfolio / Settings trader shell. It does **not** replace live `web/portal` JavaScript. **Do not deploy this as the website.**

## Toolchain used for this rewrite

| | Version |
|---|---|
| Flutter | **3.47.5** (stable) |
| Dart | **3.13.4** |
| Date | 26 Sep 2026 |

## Bottom navigation (matches live)

Home · Quotes · Chart · Trade · History

There is no Markets tab.

## APIs (same hosts as compiled portal)

| | |
|---|---|
| Trading gateway | `https://portal.burjexprime.net/v1` |
| Quotes / ticks WS | `wss://portal.burjexprime.net` |
| CRM (login, register, funding) | `https://crm.burjexprime.net/api/v1` |

Shared models and `/v1` client: path package `btrader/flutter/packages/btrader_core`.

`main()` calls `BtConfig.useLivePortalHosts()` so native/debug builds talk to live portal without `--dart-define`. Optional:

```bash
flutter run --dart-define-from-file=dart_defines.live.json
```

## Screens

| Route | Screen |
|---|---|
| `/login` `/register` `/forgot-password` `/verify-otp` | Email/password auth (no Google/Apple overlay) |
| `/home` | Account cards, Deposit / Withdraw / Trade, Quick Actions, My Fund |
| `/quotes` | Watchlist bid/ask |
| `/chart` | Candles + SELL/BUY |
| `/trade` | Open positions + market ticket |
| `/history` | Deals / balance ops |
| `/deposit` `/withdraw` `/transfer` `/transactions` | CRM funding |

## Run

```bash
cd forexten_mobile
flutter pub get
flutter run
```

Android and iOS use live HTTPS. Flutter **web on localhost** will hit CORS against portal.burjexprime.net — use a device/emulator, not Chrome-on-localhost, to log in.

## Firebase (placeholders)

Original `google-services.json` / `GoogleService-Info.plist` cannot be recovered from compiled JS. Do **not** invent project keys.

Drop the real files from the Firebase console into:

- Android: `android/app/google-services.json` (package `net.burjexprime.forexten_mobile`)
- iOS: `ios/Runner/GoogleService-Info.plist` (bundle `net.burjexprime.forexten_mobile`)

See `firebase/README.md`. `lib/services/push_service.dart` is the hook for deposit/withdrawal FCM.

## Out of scope

- Live `web/portal/**` (unchanged)
- Google/Apple sign-in UI
- FOREXTEN / `C:\burjex`
- Deploy
