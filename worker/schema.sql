-- LevelPace D1 schema.
--
-- Apply with:
--   npx wrangler d1 execute levelpace --remote --file worker/schema.sql
--
-- Design notes that matter:
--
--   char_id is DERIVED SERVER-SIDE from name@realm and is never accepted from
--   the client. An earlier draft let the client choose it, which -- combined
--   with the id appearing in a public cursor -- let any enrolled user
--   overwrite anyone else's rows using a perfectly valid key.
--
--   owner_install is the whole impersonation defence: first install to submit
--   a character owns it, and every write carries
--   `WHERE char_id = ? AND owner_install = ?`.
--
--   Only sha256(key) is stored, so a database dump contains nothing usable.

CREATE TABLE IF NOT EXISTS installs (
  install_id TEXT PRIMARY KEY,
  key_hash   TEXT NOT NULL UNIQUE,
  created    INTEGER NOT NULL,
  last_seen  INTEGER,
  submits    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS characters (
  char_id       TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  realm         TEXT NOT NULL,
  display       TEXT,
  show_realm    INTEGER NOT NULL DEFAULT 1,
  class         TEXT,
  faction       TEXT,
  level         INTEGER,
  owner_install TEXT NOT NULL,
  first_seen    INTEGER NOT NULL,
  updated       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_char_owner ON characters(owner_install);

CREATE TABLE IF NOT EXISTS levels (
  char_id  TEXT NOT NULL,
  level    INTEGER NOT NULL,
  seconds  REAL NOT NULL,
  xp       INTEGER,
  deaths   INTEGER DEFAULT 0,
  flags    TEXT,
  updated  INTEGER NOT NULL,
  PRIMARY KEY (char_id, level)
);
CREATE INDEX IF NOT EXISTS idx_levels_level ON levels(level);

CREATE TABLE IF NOT EXISTS bg_stats (
  char_id         TEXT PRIMARY KEY,
  honorable_kills INTEGER DEFAULT 0,   -- server truth, genuinely lifetime
  wins            INTEGER DEFAULT 0,   -- since install ONLY
  losses          INTEGER DEFAULT 0,   -- since install ONLY
  longest_streak  INTEGER DEFAULT 0,
  item_level      REAL,
  updated         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bg_hk ON bg_stats(honorable_kills DESC);

CREATE TABLE IF NOT EXISTS nemeses (
  char_id    TEXT NOT NULL,
  enemy_name TEXT NOT NULL,
  kills      INTEGER DEFAULT 0,
  deaths     INTEGER DEFAULT 0,
  guild      TEXT,
  PRIMARY KEY (char_id, enemy_name)
);

CREATE TABLE IF NOT EXISTS rare_kills (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  char_id   TEXT NOT NULL,
  npc_id    INTEGER NOT NULL,
  npc_name  TEXT,
  killed_at INTEGER NOT NULL,
  mine      INTEGER NOT NULL DEFAULT 1,
  learned   INTEGER NOT NULL DEFAULT 0,
  UNIQUE (char_id, npc_id, killed_at)
);
CREATE INDEX IF NOT EXISTS idx_rare_npc  ON rare_kills(npc_id, killed_at DESC);
CREATE INDEX IF NOT EXISTS idx_rare_char ON rare_kills(char_id);
CREATE INDEX IF NOT EXISTS idx_rare_time ON rare_kills(killed_at DESC);

-- Precomputed rankings. Recomputed on write rather than on read, because D1
-- bills rows READ and a leaderboard is read far more often than written.
CREATE TABLE IF NOT EXISTS parse (
  board   TEXT NOT NULL,          -- 'levelling' | 'pvp' | 'rares'
  scope   TEXT NOT NULL,          -- 'overall' or a level number as text
  char_id TEXT NOT NULL,
  metric  REAL NOT NULL,
  pct     REAL,
  band    TEXT,
  updated INTEGER NOT NULL,
  PRIMARY KEY (board, scope, char_id)
);
CREATE INDEX IF NOT EXISTS idx_parse_rank ON parse(board, scope, metric DESC);

-- v1 clients authenticate with the old shared token. They are accepted so
-- nobody's upload silently fails during the transition, but they land here:
-- never ranked, never creating ownership. A v1 blob must not be able to claim
-- a character, or the whole ownership rule is bypassable while the window is
-- open.
CREATE TABLE IF NOT EXISTS quarantine (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  payload  TEXT NOT NULL,
  reason   TEXT,
  received INTEGER NOT NULL
);

-- Rejections and flags, so abuse is visible rather than silent.
CREATE TABLE IF NOT EXISTS audit (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  install_id TEXT,
  kind       TEXT NOT NULL,
  detail     TEXT,
  at         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_at ON audit(at DESC);
-- The rate limiter filters on all three of these. With only (at) indexed,
-- every enrol and every submit scanned the table -- and D1 bills rows read,
-- so the cost grew with the table forever.
CREATE INDEX IF NOT EXISTS idx_audit_rl ON audit(kind, detail, at);

-- Companion health. Exists because a client that was running correctly but
-- had nothing to upload looked identical to one that had never been
-- installed, and that cost two days of guessing.
CREATE TABLE IF NOT EXISTS clients (
  install_id  TEXT PRIMARY KEY,
  version     TEXT,
  wow_found   INTEGER DEFAULT 0,
  addon_found INTEGER DEFAULT 0,
  blob_found  INTEGER DEFAULT 0,
  detail      TEXT,
  first_seen  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_clients_seen ON clients(last_seen DESC);
