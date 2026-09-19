-- Position lifecycle: OPEN → CLOSE_PENDING → CLOSED.
-- CLOSE_PENDING is the atomic claim after a server-tick SL/TP hit, while
-- group executionDelayMs elapses. Not HedgeStatus (MT5 covers).
-- Safe to re-run.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'PositionStatus'
      AND e.enumlabel = 'CLOSE_PENDING'
  ) THEN
    ALTER TYPE "PositionStatus" ADD VALUE 'CLOSE_PENDING';
  END IF;
END
$$;
