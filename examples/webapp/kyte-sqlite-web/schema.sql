-- Reference schema (the --migrate path applies this same DDL from main.ky).
-- SQLite: INTEGER PRIMARY KEY AUTOINCREMENT rowid, done as 0/1.
CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
