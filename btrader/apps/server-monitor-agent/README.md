# Server monitor agent

This optional process reports compact resource and health snapshots to the
gateway. It is not part of the matching process and is not started by Docker,
the production compose project, or this change.

Required environment:

```text
SERVER_MONITOR_API_URL=http://localhost:4100
SERVER_MONITOR_SERVER_ID=<monitoring_servers.id>
SERVER_MONITOR_AGENT_TOKEN=<same secret as gateway SERVER_MONITOR_AGENT_TOKEN>
```

Optional service checks are a JSON map of existing health URLs:

```text
SERVER_MONITOR_SERVICE_URLS_JSON={"gateway":"http://localhost:4100/v1/health","marketData":"http://localhost:4200/health"}
SERVER_MONITOR_INTERVAL_MS=30000
SERVER_MONITOR_APP_VERSION=git-sha-or-release
```

The agent never receives SSH credentials and cannot call restart, promotion, or
trading endpoints. Use it only in local/development verification until an
explicit production rollout is approved.
