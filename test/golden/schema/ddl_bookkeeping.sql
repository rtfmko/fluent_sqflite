-- table __fluent_fts
CREATE TABLE "__fluent_fts" (tbl TEXT PRIMARY KEY, definition TEXT NOT NULL, revision INTEGER NOT NULL);

-- table __fluent_schema
CREATE TABLE "__fluent_schema" ("table_name" TEXT PRIMARY KEY, "revision" INTEGER NOT NULL, "snapshot" TEXT NOT NULL, "updated_at" INTEGER NOT NULL);

-- table __fluent_schema_history
CREATE TABLE "__fluent_schema_history" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "table_name" TEXT NOT NULL, "from_revision" INTEGER NOT NULL, "to_revision" INTEGER NOT NULL, "changes" TEXT NOT NULL, "success" INTEGER NOT NULL, "error" TEXT, "duration_ms" INTEGER NOT NULL, "applied_at" INTEGER NOT NULL);

-- table __fluent_stats
CREATE TABLE "__fluent_stats" (key TEXT PRIMARY KEY, tbl TEXT NOT NULL, action TEXT NOT NULL, shape TEXT NOT NULL, avg_ms REAL NOT NULL, avg_rows REAL, samples INTEGER NOT NULL, failures INTEGER NOT NULL, last_used INTEGER NOT NULL);

-- table __fluent_sync_state
CREATE TABLE __fluent_sync_state (tbl TEXT PRIMARY KEY, last_pull INTEGER);

-- table __fluent_tombstones
CREATE TABLE __fluent_tombstones (tbl TEXT NOT NULL, key TEXT NOT NULL, deleted_at INTEGER NOT NULL, PRIMARY KEY (tbl, key));
