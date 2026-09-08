/// Hand-written SQL, no ORM -- mirrors db.py's own "no ORM, no migrations
/// framework" convention on the Python side. `onCreate`/`onUpgrade` in
/// UploadsDao play the role db.py's `_migrate()` guarded-ALTER pattern
/// plays there: this file only has version 1 today, but a future column
/// addition should follow the same shape (bump schemaVersion, add a
/// guarded `ALTER TABLE ... ADD COLUMN` in onUpgrade, never rewrite
/// createUploadsTableSql itself for an already-shipped version).
library;

const int schemaVersion = 1;

/// sha256 is nullable and UNIQUE, not NOT NULL UNIQUE: a row is inserted
/// the moment a file is picked (state=PENDING), before hashing has run.
/// SQLite's UNIQUE constraint permits any number of NULLs, so several
/// not-yet-hashed rows coexist fine -- uniqueness only bites once a real
/// hash is set, which is exactly the point (re-picking the same content
/// collapses onto the existing row; see UploadsDao.setHashComputed).
const String createUploadsTableSql = '''
CREATE TABLE IF NOT EXISTS uploads (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  local_uri         TEXT    NOT NULL,
  local_path        TEXT    NOT NULL,
  filename          TEXT    NOT NULL,
  size_bytes        INTEGER NOT NULL,
  sha256            TEXT    UNIQUE,
  captured_at       TEXT,
  added_at          TEXT    NOT NULL,
  updated_at        TEXT    NOT NULL,
  state             TEXT    NOT NULL,
  server_upload_id  TEXT,
  server_file_id    INTEGER,
  server_state      TEXT,
  bytes_sent        INTEGER NOT NULL DEFAULT 0,
  attempts          INTEGER NOT NULL DEFAULT 0,
  last_error        TEXT,
  confirmed_at      TEXT,
  deleted_at        TEXT
)
''';

const String createStateIndexSql =
    'CREATE INDEX IF NOT EXISTS idx_uploads_state ON uploads(state)';
