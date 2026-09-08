# 4. Mobile Application Architecture

React Native (Expo) for one codebase across **Android and iOS**, white-labeled per tenant. Source: `mobile/`.

## Stack
- **Expo / React Native 0.74** — single codebase, OTA updates, store builds per brand.
- **Zustand** — lightweight global state for auth, quotes, positions, account, and theme.
- **@tanstack/react-query** — server cache for REST reads (symbols, history) with retry/stale handling.
- **axios** — REST client with automatic token attach + transparent 401 refresh (`src/api/client.ts`).
- **Native WebSocket** — `MarketSocket` (`src/ws/market-socket.ts`): auto-reconnect with backoff, re-subscribe on reconnect, heartbeat ping.
- **react-native-mmkv** — fast encrypted local storage for tokens.

## State model
- `store/auth.ts` — tokens, role, tenant `apiBase`; `login` / `refresh` / `logout`.
- `store/trading.ts` — `quotes` (by symbol), `account` snapshot, `positions` (by id). Fed entirely by the WebSocket so the UI is always live.
- `theme/index.ts` — branding (app name, logo, colors) hydrated at launch from the tenant; drives every screen's look.

## Navigation (full app)
Auth stack (login, MFA) → main tab navigator:
1. **Markets** — `Watchlist` of enabled symbols with live bid/ask.
2. **Trade** — `OrderTicket`: all eight order types + one-click BUY/SELL, SL/TP fields.
3. **Portfolio** — `Positions` (modify SL/TP, partial/full close, close-all) + `AccountPanel` (Balance, Equity, Margin, Free Margin, Margin Level, Floating P/L, Credit/Bonus, Dividend) shown MT5-style.
4. **History** — closed deals via `/history/deals`.
5. **Account** — profile, leverage display, logout.

## Realtime loop
On login the app opens the WS with the access token, subscribes to its watchlist symbols, and `watch_account`s the active account. Ticks update quotes instantly; the engine's `ACCOUNT_UPDATE`/`POSITION_UPDATE` events update the account panel and positions list without polling. Orders are placed over REST and the resulting fill is reflected both in the HTTP response and the next pushed snapshot.

## White-labeling
Each broker gets its own store listing (bundle id / package name from `TenantBranding`), but all brands run the same binary logic. At runtime the app resolves its tenant `apiBase` (compile-time constant per white-label build, or chosen at first launch) and pulls branding so colors, logo, and app name match the broker. No code fork per brand.

## Offline & resilience
Tokens persist in MMKV so the app resumes without re-login. The WS reconnects automatically; REST reads are cached by react-query so the UI degrades gracefully when the network blips.
