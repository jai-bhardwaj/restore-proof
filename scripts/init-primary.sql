-- A table with enough shape to prove a restore actually restored something:
-- a monetary sum that must survive, and a timestamp to recover to.
CREATE TABLE IF NOT EXISTS ledger (
    id          bigserial PRIMARY KEY,
    account     text        NOT NULL,
    amount      numeric(14,2) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ledger (account, amount)
SELECT 'acct-' || (i % 50), round((random() * 1000)::numeric, 2)
FROM generate_series(1, 5000) AS i;

-- Replication user for the standby.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator';
    END IF;
END
$$;
