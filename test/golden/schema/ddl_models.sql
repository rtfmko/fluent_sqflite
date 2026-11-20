-- table composite
CREATE TABLE "composite" (
  "a" TEXT NOT NULL,
  "b" TEXT NOT NULL,
  "v" TEXT,
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER,
  PRIMARY KEY ("a", "b")
) WITHOUT ROWID;

-- table fx_authors
CREATE TABLE "fx_authors" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT,
  "born" INTEGER,
  "rating" REAL,
  "active" INTEGER CHECK ("active" IN (0, 1)),
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER
);

-- table fx_authors_fx_tags
CREATE TABLE "fx_authors_fx_tags" (
  "fx_author_id" INTEGER NOT NULL,
  "fx_tag_id" INTEGER NOT NULL,
  PRIMARY KEY ("fx_author_id", "fx_tag_id"),
  FOREIGN KEY ("fx_author_id") REFERENCES "fx_authors"("id") ON DELETE CASCADE,
  FOREIGN KEY ("fx_tag_id") REFERENCES "fx_tags"("id") ON DELETE CASCADE
);

-- table fx_books
CREATE TABLE "fx_books" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "title" TEXT,
  "pages" INTEGER,
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER,
  "fx_author_id" INTEGER REFERENCES "fx_authors"("id") ON DELETE CASCADE,
  "deleted_at" INTEGER,
  "created_at" INTEGER,
  "updated_at" INTEGER
);

-- table fx_cached
CREATE TABLE "fx_cached" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "value" TEXT,
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER
);

-- table fx_events
CREATE TABLE "fx_events" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "at" INTEGER,
  "note" TEXT,
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER
);

-- table fx_tags
CREATE TABLE "fx_tags" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "label" TEXT,
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER
);

-- table fx_todos
CREATE TABLE "fx_todos" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "text" TEXT,
  "done" INTEGER CHECK ("done" IN (0, 1)),
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER,
  "sync_version" INTEGER NOT NULL DEFAULT 1,
  "synced_version" INTEGER NOT NULL DEFAULT 0
);

-- table plain_types
CREATE TABLE "plain_types" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT NOT NULL UNIQUE DEFAULT 'n' COLLATE NOCASE,
  "qty" INTEGER DEFAULT 0,
  "score" REAL,
  "flag" INTEGER DEFAULT 0 CHECK ("flag" IN (0, 1)),
  "at" INTEGER,
  "raw" BLOB,
  "_fs_metadata" TEXT,
  "expiry_date" INTEGER,
  CHECK ("qty" >= 0)
);

-- index idx_composite_expiry_date
CREATE INDEX "idx_composite_expiry_date" ON "composite" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_fx_authors_expiry_date
CREATE INDEX "idx_fx_authors_expiry_date" ON "fx_authors" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_fx_authors_fx_tags_fx_tag_id
CREATE INDEX "idx_fx_authors_fx_tags_fx_tag_id" ON "fx_authors_fx_tags" ("fx_tag_id");

-- index idx_fx_books_deleted_at
CREATE INDEX "idx_fx_books_deleted_at" ON "fx_books" ("deleted_at") WHERE "deleted_at" IS NOT NULL;

-- index idx_fx_books_expiry_date
CREATE INDEX "idx_fx_books_expiry_date" ON "fx_books" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_fx_books_fx_author_id
CREATE INDEX "idx_fx_books_fx_author_id" ON "fx_books" ("fx_author_id");

-- index idx_fx_cached_expiry_date
CREATE INDEX "idx_fx_cached_expiry_date" ON "fx_cached" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_fx_events_expiry_date
CREATE INDEX "idx_fx_events_expiry_date" ON "fx_events" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_fx_tags_expiry_date
CREATE INDEX "idx_fx_tags_expiry_date" ON "fx_tags" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_fx_todos_expiry_date
CREATE INDEX "idx_fx_todos_expiry_date" ON "fx_todos" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_plain_combo
CREATE UNIQUE INDEX "idx_plain_combo" ON "plain_types" ("name", "qty");

-- index idx_plain_types_expiry_date
CREATE INDEX "idx_plain_types_expiry_date" ON "plain_types" ("expiry_date") WHERE "expiry_date" IS NOT NULL;

-- index idx_plain_types_qty
CREATE INDEX "idx_plain_types_qty" ON "plain_types" ("qty");
