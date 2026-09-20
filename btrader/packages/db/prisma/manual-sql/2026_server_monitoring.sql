-- Admin Servers monitoring registry. Apply with the normal database migration
-- process before enabling the UI; this migration does not touch order, deal,
-- position, or matching tables.
DO $$ BEGIN
  CREATE TYPE "MonitoringServerRole" AS ENUM ('PRIMARY', 'STANDBY');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE "MonitoringServerReadiness" AS ENUM (
    'NOT_READY', 'ONBOARDING', 'READY', 'ACTIVE', 'STANDBY', 'MAINTENANCE', 'ERROR'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS "monitoring_servers" (
  "id" TEXT PRIMARY KEY,
  "name" TEXT NOT NULL UNIQUE,
  "host" TEXT NOT NULL,
  "sshPort" INTEGER NOT NULL DEFAULT 22,
  "region" TEXT,
  "environment" TEXT NOT NULL DEFAULT 'production',
  "role" "MonitoringServerRole" NOT NULL DEFAULT 'STANDBY',
  "readiness" "MonitoringServerReadiness" NOT NULL DEFAULT 'NOT_READY',
  "enabled" BOOLEAN NOT NULL DEFAULT TRUE,
  "appVersion" TEXT,
  "lastHeartbeatAt" TIMESTAMP(3),
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "monitoring_server_heartbeats" (
  "id" TEXT PRIMARY KEY,
  "serverId" TEXT NOT NULL REFERENCES "monitoring_servers"("id") ON DELETE CASCADE,
  "reportedAt" TIMESTAMP(3),
  "receivedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "cpuPercent" DOUBLE PRECISION,
  "ramPercent" DOUBLE PRECISION,
  "diskPercent" DOUBLE PRECISION,
  "uptimeSeconds" INTEGER,
  "appVersion" TEXT,
  "network" JSONB,
  "services" JSONB
);

CREATE TABLE IF NOT EXISTS "monitoring_server_events" (
  "id" TEXT PRIMARY KEY,
  "serverId" TEXT NOT NULL REFERENCES "monitoring_servers"("id") ON DELETE CASCADE,
  "kind" TEXT NOT NULL,
  "severity" TEXT NOT NULL DEFAULT 'INFO',
  "message" TEXT NOT NULL,
  "detail" JSONB,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS "monitoring_server_health_settings" (
  "id" TEXT PRIMARY KEY DEFAULT 'default',
  "cpuWarningPercent" INTEGER NOT NULL DEFAULT 70,
  "cpuCriticalPercent" INTEGER NOT NULL DEFAULT 85,
  "ramWarningPercent" INTEGER NOT NULL DEFAULT 70,
  "ramCriticalPercent" INTEGER NOT NULL DEFAULT 85,
  "diskWarningPercent" INTEGER NOT NULL DEFAULT 70,
  "diskCriticalPercent" INTEGER NOT NULL DEFAULT 85,
  "heartbeatWarningSeconds" INTEGER NOT NULL DEFAULT 90,
  "heartbeatOfflineSeconds" INTEGER NOT NULL DEFAULT 180,
  "maxHeartbeatsPerServer" INTEGER NOT NULL DEFAULT 1440,
  "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "monitoring_servers_enabled_readiness_idx"
  ON "monitoring_servers" ("enabled", "readiness");
CREATE INDEX IF NOT EXISTS "monitoring_servers_role_idx"
  ON "monitoring_servers" ("role");
CREATE INDEX IF NOT EXISTS "monitoring_server_heartbeats_serverId_receivedAt_idx"
  ON "monitoring_server_heartbeats" ("serverId", "receivedAt");
CREATE INDEX IF NOT EXISTS "monitoring_server_events_serverId_createdAt_idx"
  ON "monitoring_server_events" ("serverId", "createdAt");

INSERT INTO "monitoring_server_health_settings" ("id")
VALUES ('default')
ON CONFLICT ("id") DO NOTHING;

-- Registry-only seed for the current singleton architecture. It has no
-- heartbeat until an agent is explicitly configured and started.
INSERT INTO "monitoring_servers"
  ("id", "name", "host", "environment", "role", "readiness", "enabled")
VALUES
  ('forexten-registry-only', 'FOREXTEN (registry only)', '5.226.139.8',
   'production', 'PRIMARY', 'NOT_READY', TRUE)
ON CONFLICT ("name") DO NOTHING;
