CREATE TABLE goals (
    thread_id TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

INSERT INTO goals VALUES ('cli-1', 'active', 1700000010000);
INSERT INTO goals VALUES ('desktop-1', 'complete', 1700000011000);
