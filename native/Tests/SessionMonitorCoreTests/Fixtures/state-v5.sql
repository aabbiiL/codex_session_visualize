CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    rollout_path TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    source TEXT NOT NULL,
    cwd TEXT NOT NULL,
    title TEXT NOT NULL,
    archived INTEGER NOT NULL,
    agent_nickname TEXT,
    agent_role TEXT,
    thread_source TEXT,
    recency_at_ms INTEGER NOT NULL
);

CREATE TABLE thread_spawn_edges (
    parent_thread_id TEXT NOT NULL,
    child_thread_id TEXT NOT NULL
);

INSERT INTO threads VALUES (
    'desktop-1',
    '/tmp/codex-fixture/rollouts/desktop-1.jsonl',
    1700000000000,
    1700000001000,
    'app_server',
    '/tmp/codex-fixture/desktop-workspace',
    'Desktop fixture',
    0,
    NULL,
    NULL,
    'desktop',
    1700000001100
);

INSERT INTO threads VALUES (
    'cli-1',
    '/tmp/codex-fixture/rollouts/cli-1.jsonl',
    1700000002000,
    1700000003000,
    'cli',
    '/tmp/codex-fixture/cli-workspace',
    'CLI fixture',
    0,
    NULL,
    NULL,
    NULL,
    1700000003100
);

INSERT INTO threads VALUES (
    'ide-1',
    '/tmp/codex-fixture/rollouts/ide-1.jsonl',
    1700000004000,
    1700000005000,
    'vscode',
    '/tmp/codex-fixture/ide-workspace',
    'IDE fixture',
    0,
    NULL,
    NULL,
    NULL,
    1700000005100
);

INSERT INTO threads VALUES (
    'subagent-1',
    '/tmp/codex-fixture/rollouts/subagent-1.jsonl',
    1700000006000,
    1700000007000,
    'cli',
    '/tmp/codex-fixture/cli-workspace',
    'Sub-agent fixture',
    0,
    'fixture-agent',
    'worker',
    NULL,
    1700000007100
);

INSERT INTO threads VALUES (
    'archived-1',
    '/tmp/codex-fixture/rollouts/archived-1.jsonl',
    1700000008000,
    1700000009000,
    'app_server',
    '/tmp/codex-fixture/archived-workspace',
    'Archived fixture',
    1,
    NULL,
    NULL,
    'desktop',
    1700000009100
);

INSERT INTO thread_spawn_edges VALUES ('cli-1', 'subagent-1');
