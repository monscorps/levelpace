/**
 * LevelPace API — Cloudflare Worker + D1.
 *
 * Replaces the Python server that ran on a Mac behind a quick tunnel whose URL
 * changed on every restart.
 *
 * The security model, stated plainly:
 *
 *   - Enrolment issues a random key. Only sha256(key) is stored, so a database
 *     dump contains nothing usable and there is no root secret to leak.
 *   - char_id is DERIVED from name@realm server-side. A client-supplied charId
 *     is ignored: it was previously client-chosen AND publicly enumerable,
 *     which let any enrolled user overwrite anyone's rows with a valid key.
 *   - First install to submit a character owns it. Every write carries
 *     `WHERE char_id = ? AND owner_install = ?`.
 *
 * What this does NOT do: stop you faking your own numbers. The data is
 * produced by a client the player controls, in a file they can edit. Nothing
 * here makes "is this number true" answerable, and nothing in this file should
 * ever claim otherwise.
 */

const WCL_BANDS = [
  { min: 100, band: 'gold' },
  { min: 99, band: 'pink' },
  { min: 95, band: 'orange' },
  { min: 75, band: 'purple' },
  { min: 50, band: 'blue' },
  { min: 25, band: 'green' },
  { min: 0, band: 'grey' },
];

const LIMITS = {
  enrol: { n: 5, windowMs: 3600_000 },
  submit: { n: 60, windowMs: 3600_000 },
  legacy: { n: 10, windowMs: 3600_000 },
};

// Bounds. Reject the impossible; flag the merely implausible. Deliberately
// wide: this is a private server with custom XP rates and custom items, so a
// "surely nobody levels that fast" bound would reject honest players.
const BOUNDS = {
  levelMin: 1,
  levelMax: 80,
  // Reject-impossible only. The floor was 30s, which sounded safe and was
  // not: this targets private servers with boosted XP rates, where level 1->2
  // at x5 is two or three kills and legitimately finishes in well under 30
  // seconds. A 30s floor would have silently rejected the first levels of
  // exactly the fresh-character test it was about to be used for. Five
  // seconds is genuinely impossible -- less time than killing two mobs --
  // and everything between 5s and 30s is merely flagged.
  secondsMin: 5,
  secondsFlag: 30,
  secondsMax: 60 * 60 * 24 * 30,
  npcIdMax: 0xffffff, // 24-bit creature entry
  hkMax: 5_000_000,
};

const json = (data, status = 200, extra = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'access-control-allow-origin': '*',
      'cache-control': 'no-store',
      ...extra,
    },
  });

const now = () => Math.floor(Date.now() / 1000);

async function sha256Hex(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomKey() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/** Derived, never client-supplied. Realm is part of the key so two players
 *  genuinely named Thrall on different realms do not collide. */
async function charIdFor(name, realm) {
  const key = `${String(name).toLowerCase()}@${String(realm).toLowerCase()}`;
  return (await sha256Hex(key)).slice(0, 16);
}

/**
 * Coerce to an array.
 *
 * Lua cannot distinguish an empty array from an empty table, so the addon's
 * JSON encoder emits `"levels": {}` rather than `[]` when a player has no
 * level records yet. Iterating that throws, and it throws on exactly the blob
 * a NEW player sends -- the worst possible case to get wrong.
 */
function asArray(v) {
  if (Array.isArray(v)) return v;
  if (v && typeof v === 'object') return Object.values(v);
  return [];
}

async function auth(req, env) {
  const header = req.headers.get('authorization') || '';
  const m = header.match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const hash = await sha256Hex(m[1]);
  const row = await env.DB.prepare('SELECT install_id FROM installs WHERE key_hash = ?')
    .bind(hash)
    .first();
  return row ? row.install_id : null;
}

/** Fixed-window limiter kept in D1 so it survives isolate churn. Coarse on
 *  purpose: this exists to stop board-stuffing, not to be a precise quota. */
async function rateLimited(env, bucket, id, spec) {
  const since = now() - Math.floor(spec.windowMs / 1000);
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM audit WHERE kind = ? AND detail = ? AND at > ?'
  )
    .bind(`rl:${bucket}`, id, since)
    .first();
  if ((row?.n ?? 0) >= spec.n) return true;
  await env.DB.prepare('INSERT INTO audit (install_id, kind, detail, at) VALUES (?, ?, ?, ?)')
    .bind(null, `rl:${bucket}`, id, now())
    .run();
  return false;
}

function bandFor(pct) {
  if (pct == null) return null;
  for (const b of WCL_BANDS) if (pct >= b.min) return b.band;
  return 'grey';
}

/**
 * Percentile of `value` within `all`, EXCLUDING the player's own entry.
 *
 * The divisor is n-1, not n. With n as the divisor the faster of two players
 * caps at 50%, which is wrong and was a real bug. A population of one returns
 * null: there is nothing to compare against, and 100 would be a lie.
 */
function percentile(value, all) {
  const others = all.length - 1;
  if (others <= 0) return null;
  let below = 0;
  for (const v of all) if (v < value) below++;
  return Math.max(0, Math.min(100, (below / others) * 100));
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * The addon emits `elapsed`; this used to read only `seconds`, so every level
 * uploaded cleanly and was rejected as "non-positive time". The client name
 * is already in the wild, so accept both rather than requiring everyone to
 * update in lockstep.
 */
function levelSeconds(row) {
  const v = row.elapsed != null ? row.elapsed : row.seconds;
  return Number(v);
}

/** XP is split by source in the addon; the board wants the total. */
function levelXP(row) {
  if (row.xp != null) return Number(row.xp) || 0;
  return (Number(row.kill) || 0) + (Number(row.quest) || 0) +
         (Number(row.explore) || 0) + (Number(row.unknown) || 0);
}

function inspectLevel(row) {
  const flags = [];
  const level = Number(row.level);
  const seconds = levelSeconds(row);
  if (!Number.isFinite(level) || level < BOUNDS.levelMin || level > BOUNDS.levelMax)
    return { reject: `level out of range: ${row.level}` };
  if (!Number.isFinite(seconds) || seconds <= 0) return { reject: 'non-positive time' };
  if (seconds < BOUNDS.secondsMin) return { reject: `level in ${seconds}s is not playable` };
  if (seconds < BOUNDS.secondsFlag) flags.push('very-fast');
  if (seconds > BOUNDS.secondsMax) flags.push('very-slow');
  return { flags };
}

function inspectRare(row) {
  const npc = Number(row.npc);
  if (!Number.isFinite(npc) || npc <= 0 || npc > BOUNDS.npcIdMax)
    return { reject: `npc id out of 24-bit range: ${row.npc}` };
  const t = Number(row.t);
  if (!Number.isFinite(t) || t <= 0) return { reject: 'missing timestamp' };
  // Small tolerance for clock skew; anything further ahead is not a real kill.
  if (t > now() + 3600) return { reject: 'timestamp in the future' };
  return { flags: row.learned ? ['learned-only'] : [] };
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

async function handleEnrol(req, env) {
  const ip = req.headers.get('cf-connecting-ip') || 'unknown';
  if (await rateLimited(env, 'enrol', ip, LIMITS.enrol))
    return json({ error: 'too many enrolments from this address' }, 429);

  const key = randomKey();
  const hash = await sha256Hex(key);
  const installId = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO installs (install_id, key_hash, created) VALUES (?, ?, ?)')
    .bind(installId, hash, now())
    .run();

  // The key is returned exactly once and never stored in recoverable form.
  return json({
    installId,
    key,
    note: 'Keep this key. It is not recoverable: losing it means you can no longer add to your own history.',
  });
}

/**
 * A heartbeat.
 *
 * Enrolment used to happen only when there was something to send, so a
 * companion that was running perfectly but had nothing to upload was
 * indistinguishable from one that had never been installed. Two days were
 * spent guessing at a client that was alive the whole time and could not say
 * so. This is that channel: it reports what the companion can and cannot see,
 * so a failure is visible to the operator instead of only in a log file on
 * someone else's machine.
 */
async function handleHello(req, env) {
  const installId = await auth(req, env);
  if (!installId) return json({ error: 'unauthorised' }, 401);

  const body = await req.json().catch(() => ({}));
  const t = now();
  await env.DB.prepare(
    `INSERT INTO clients (install_id, version, wow_found, addon_found, blob_found,
                          detail, first_seen, last_seen)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(install_id) DO UPDATE SET
       version = excluded.version, wow_found = excluded.wow_found,
       addon_found = excluded.addon_found, blob_found = excluded.blob_found,
       detail = excluded.detail, last_seen = excluded.last_seen`
  )
    .bind(installId, String(body.version || '?').slice(0, 32),
          body.wowFound ? 1 : 0, body.addonFound ? 1 : 0, body.blobFound ? 1 : 0,
          String(body.detail || '').slice(0, 300), t, t)
    .run();

  return json({ ok: true, seen: t });
}

/** Coarse client health. Names nothing about the player -- only whether a
 *  companion is alive and which of its three preconditions are met. */
async function handleClients(env) {
  const rs = await env.DB.prepare(
    `SELECT version, wow_found, addon_found, blob_found, detail, last_seen
       FROM clients ORDER BY last_seen DESC LIMIT 50`
  ).all();
  return json({
    clients: (rs.results || []).map((c) => ({
      version: c.version,
      wowFound: !!c.wow_found,
      addonFound: !!c.addon_found,
      blobFound: !!c.blob_found,
      detail: c.detail || null,
      lastSeen: c.last_seen,
    })),
  });
}

async function handleSubmit(req, env) {
  const installId = await auth(req, env);
  const body = await req.json().catch(() => null);
  if (!body) return json({ error: 'invalid JSON' }, 400);

  // Legacy v1 clients: accepted so nobody's upload silently fails during the
  // transition, but quarantined. They never create ownership and never rank.
  if (!installId) {
    const legacy = req.headers.get('x-levelpace-token');
    if (legacy && env.LEGACY_TOKEN && legacy === env.LEGACY_TOKEN) {
      // This path used to return BEFORE any rate limiting, and the token it
      // accepts shipped inside every download -- so anyone holding it could
      // write unlimited 100KB rows into D1 forever. It is a transition
      // courtesy, not a trusted caller, and is limited accordingly.
      const ip = req.headers.get('cf-connecting-ip') || 'unknown';
      if (await rateLimited(env, 'legacy', ip, LIMITS.legacy))
        return json({ error: 'too many legacy submissions' }, 429);

      await env.DB.prepare(
        'INSERT INTO quarantine (payload, reason, received) VALUES (?, ?, ?)'
      )
        .bind(JSON.stringify(body).slice(0, 20_000), 'legacy-token', now())
        .run();
      return json({
        ok: true,
        quarantined: true,
        message: 'Accepted but not ranked. Update your companion to appear on the board.',
      });
    }
    return json({ error: 'unauthorised' }, 401);
  }

  if (await rateLimited(env, 'submit', installId, LIMITS.submit))
    return json({ error: 'too many submissions' }, 429);

  const blobs = Array.isArray(body) ? body : [body];  // a companion may batch several characters
  const results = [];

  for (const blob of blobs) {
   // One malformed character must not abort the rest of the batch, and must
   // not leave the caller unsure what landed. Without this, a blob that threw
   // halfway had already claimed the character -- so a retry looked like an
   // impersonation attempt against the caller's own first attempt.
   try {
    const name = blob.name;
    const realm = blob.realm;
    if (!name || !realm) {
      results.push({ error: 'blob is missing name or realm' });
      continue;
    }

    const charId = await charIdFor(name, realm);

    // First writer owns the character.
    const existing = await env.DB.prepare(
      'SELECT owner_install FROM characters WHERE char_id = ?'
    )
      .bind(charId)
      .first();

    if (existing && existing.owner_install !== installId) {
      await env.DB.prepare(
        'INSERT INTO audit (install_id, kind, detail, at) VALUES (?, ?, ?, ?)'
      )
        .bind(installId, 'ownership-conflict', charId, now())
        .run();
      results.push({
        char: name,
        error: 'This character is already claimed by another installation.',
      });
      continue;
    }

    const t = now();
    if (!existing) {
      await env.DB.prepare(
        `INSERT INTO characters
           (char_id, name, realm, display, show_realm, class, faction, level,
            owner_install, first_seen, updated)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
        .bind(
          charId, name, realm, blob.display || name,
          blob.showRealm === false ? 0 : 1,
          blob.class || null, blob.faction || null, blob.level || null,
          installId, t, t
        )
        .run();
    } else {
      await env.DB.prepare(
        `UPDATE characters SET display = ?, show_realm = ?, class = ?, faction = ?,
                               level = ?, updated = ?
         WHERE char_id = ? AND owner_install = ?`
      )
        .bind(
          blob.display || name, blob.showRealm === false ? 0 : 1,
          blob.class || null, blob.faction || null, blob.level || null, t,
          charId, installId
        )
        .run();
    }

    const accepted = { levels: 0, rares: 0 };
    const rejected = [];

    for (const lv of asArray(blob.levels)) {
      const v = inspectLevel(lv);
      if (v.reject) { rejected.push(v.reject); continue; }
      await env.DB.prepare(
        `INSERT INTO levels (char_id, level, seconds, xp, deaths, flags, updated)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(char_id, level) DO UPDATE SET
           seconds = excluded.seconds, xp = excluded.xp,
           deaths = excluded.deaths, flags = excluded.flags,
           updated = excluded.updated`
      )
        .bind(charId, lv.level, levelSeconds(lv), levelXP(lv), lv.deaths ?? 0,
              (v.flags || []).join(',') || null, t)
        .run();
      accepted.levels++;
    }

    // Prefer the Nemesis payload (schema 2). blob.pvp is the older PvP
    // module's shape and uses different field names, so it is mapped rather
    // than read directly -- reading blob.pvp.honorableKills would silently
    // record zero for every legacy client.
    const nem = blob.nemesis;
    const legacyPvp = blob.pvp;
    const pvp = nem
      ? {
          honorableKills: nem.honorableKills ?? 0,
          wins: nem.wins ?? 0,
          losses: nem.losses ?? 0,
          longestStreak: nem.longestStreak ?? 0,
          itemLevel: legacyPvp?.itemLevel ?? null,
          nemeses: asArray(nem.nemeses),
        }
      : legacyPvp
        ? {
            honorableKills: legacyPvp.lifetimeKills ?? 0,
            wins: 0,
            losses: 0,
            longestStreak: legacyPvp.bestStreak ?? 0,
            itemLevel: legacyPvp.itemLevel ?? null,
            nemeses: [],
          }
        : null;
    if (pvp) {
      await env.DB.prepare(
        `INSERT INTO bg_stats
           (char_id, honorable_kills, wins, losses, longest_streak, item_level, updated)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(char_id) DO UPDATE SET
           honorable_kills = excluded.honorable_kills, wins = excluded.wins,
           losses = excluded.losses, longest_streak = excluded.longest_streak,
           item_level = excluded.item_level, updated = excluded.updated`
      )
        .bind(charId, Math.min(pvp.honorableKills ?? 0, BOUNDS.hkMax),
              pvp.wins ?? 0, pvp.losses ?? 0, pvp.longestStreak ?? 0,
              pvp.itemLevel ?? null, t)
        .run();

      for (const n of asArray(pvp.nemeses)) {
        if (!n.name) continue;
        await env.DB.prepare(
          `INSERT INTO nemeses (char_id, enemy_name, kills, deaths, guild)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(char_id, enemy_name) DO UPDATE SET
             kills = excluded.kills, deaths = excluded.deaths, guild = excluded.guild`
        )
          .bind(charId, n.name, n.kills ?? 0, n.deaths ?? 0, n.guild ?? null)
          .run();
      }
    }

    for (const r of asArray(blob.rares)) {
      const v = inspectRare(r);
      if (v.reject) { rejected.push(v.reject); continue; }
      await env.DB.prepare(
        `INSERT OR IGNORE INTO rare_kills
           (char_id, npc_id, npc_name, killed_at, mine, learned)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
        .bind(charId, r.npc, r.name ?? null, r.t, r.mine ? 1 : 0, r.learned ? 1 : 0)
        .run();
      accepted.rares++;
    }

    if (rejected.length) {
      await env.DB.prepare(
        'INSERT INTO audit (install_id, kind, detail, at) VALUES (?, ?, ?, ?)'
      )
        .bind(installId, 'rejected', rejected.slice(0, 5).join('; '), now())
        .run();
    }

    results.push({ char: name, accepted, rejected: rejected.length });
   } catch (err) {
    await env.DB.prepare(
      'INSERT INTO audit (install_id, kind, detail, at) VALUES (?, ?, ?, ?)'
    )
      .bind(installId, 'blob-error', String(err && err.message).slice(0, 500), now())
      .run();
    results.push({ char: blob && blob.name, error: 'could not be processed' });
   }
  }

  await env.DB.prepare(
    'UPDATE installs SET last_seen = ?, submits = submits + 1 WHERE install_id = ?'
  )
    .bind(now(), installId)
    .run();

  await recomputeParse(env);
  // Deterministic from the clock rather than Math.random: same effect, and it
  // cannot accidentally fire on every request in a bad run.
  if (now() % 50 === 0) await pruneAudit(env);
  return json({ ok: true, results });
}

/**
 * Recompute rankings on WRITE, not on read: D1 bills rows read, and a board is
 * read far more often than it is written.
 */
/**
 * The audit table backs rate limiting AND grows forever. D1 bills rows read,
 * so an unpruned table makes every single request progressively more
 * expensive and slower -- a cost leak rather than a crash, which is why it
 * would have gone unnoticed.
 *
 * Pruned opportunistically rather than on a schedule: no cron to forget, and
 * the work lands on roughly one request in fifty.
 */
async function pruneAudit(env) {
  const cutoff = now() - 7 * 24 * 3600;
  await env.DB.prepare('DELETE FROM audit WHERE at < ?').bind(cutoff).run();
  await env.DB.prepare('DELETE FROM quarantine WHERE received < ?').bind(cutoff).run();
}

async function recomputeParse(env) {
  const t = now();

  // Levelling: levels per hour, overall.
  const lv = await env.DB.prepare(
    `SELECT char_id, SUM(seconds) AS s, COUNT(*) AS n FROM levels GROUP BY char_id`
  ).all();
  const rates = (lv.results || [])
    .filter((r) => r.s > 0)
    .map((r) => ({ char_id: r.char_id, metric: (r.n / r.s) * 3600 }));
  await writeParse(env, 'levelling', 'overall', rates, t);

  // PvP: honorable kills.
  const bg = await env.DB.prepare(
    `SELECT char_id, honorable_kills AS metric FROM bg_stats WHERE honorable_kills > 0`
  ).all();
  await writeParse(env, 'pvp', 'overall', bg.results || [], t);

  // Rares: kill COUNT, exactly as asked. A count rewards volume -- that is a
  // real property and it is noted in the spec -- but the requested board is a
  // count board with colour bands, so that is what is built.
  const rare = await env.DB.prepare(
    `SELECT char_id, COUNT(*) AS metric FROM rare_kills GROUP BY char_id`
  ).all();
  await writeParse(env, 'rares', 'overall', rare.results || [], t);
}

async function writeParse(env, board, scope, rows, t) {
  if (!rows.length) return;
  const all = rows.map((r) => r.metric);
  const stmts = rows.map((r) => {
    const pct = percentile(r.metric, all);
    return env.DB.prepare(
      `INSERT INTO parse (board, scope, char_id, metric, pct, band, updated)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(board, scope, char_id) DO UPDATE SET
         metric = excluded.metric, pct = excluded.pct,
         band = excluded.band, updated = excluded.updated`
    ).bind(board, scope, r.char_id, r.metric, pct, bandFor(pct), t);
  });
  await env.DB.batch(stmts);
}

async function handleLeaderboard(url, env) {
  const board = url.searchParams.get('board') || 'levelling';
  const scope = url.searchParams.get('scope') || 'overall';
  const limit = Math.min(Number(url.searchParams.get('limit')) || 50, 200);

  const rs = await env.DB.prepare(
    `SELECT p.char_id, p.metric, p.pct, p.band,
            c.display, c.realm, c.show_realm, c.class, c.faction, c.level
       FROM parse p JOIN characters c ON c.char_id = p.char_id
      WHERE p.board = ? AND p.scope = ?
      ORDER BY p.metric DESC
      LIMIT ?`
  )
    .bind(board, scope, limit)
    .all();

  return json({
    board,
    scope,
    updated: now(),
    entries: (rs.results || []).map((r, i) => ({
      rank: i + 1,
      name: r.display,
      realm: r.show_realm ? r.realm : null,
      class: r.class,
      faction: r.faction,
      level: r.level,
      metric: r.metric,
      percentile: r.pct,
      band: r.band,
    })),
  });
}

async function handleRareLog(url, env) {
  const limit = Math.min(Number(url.searchParams.get('limit')) || 50, 200);
  const before = Number(url.searchParams.get('before')) || now() + 1;
  const rs = await env.DB.prepare(
    `SELECT r.npc_id, r.npc_name, r.killed_at, r.mine, r.learned, c.display
       FROM rare_kills r JOIN characters c ON c.char_id = r.char_id
      WHERE r.killed_at < ?
      ORDER BY r.killed_at DESC
      LIMIT ?`
  )
    .bind(before, limit)
    .all();
  const rows = rs.results || [];
  return json({
    kills: rows.map((r) => ({
      npc: r.npc_id,
      name: r.npc_name,
      at: r.killed_at,
      by: r.display,
      witnessed: !r.mine,
      learned: !!r.learned,
    })),
    // Keyset pagination: an unbounded ORDER BY over the kill log is the one
    // query here that could plausibly exhaust D1's free rows-read allowance.
    nextBefore: rows.length === limit ? rows[rows.length - 1].killed_at : null,
  });
}

async function handleStats(env) {
  const q = async (sql) => (await env.DB.prepare(sql).first()) || {};
  const chars = await q('SELECT COUNT(*) AS n FROM characters');
  const levels = await q('SELECT COUNT(*) AS n FROM levels');
  const rares = await q('SELECT COUNT(*) AS n FROM rare_kills');
  const installs = await q('SELECT COUNT(*) AS n FROM installs');
  const quar = await q('SELECT COUNT(*) AS n FROM quarantine');
  return json({
    ok: true,
    characters: chars.n ?? 0,
    levels: levels.n ?? 0,
    rareKills: rares.n ?? 0,
    installs: installs.n ?? 0,
    quarantined: quar.n ?? 0,
    updated: now(),
  });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    if (req.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'authorization, content-type, x-levelpace-token',
        },
      });
    }

    try {
      if (url.pathname === '/api/enrol' && req.method === 'POST')
        return await handleEnrol(req, env);
      if (url.pathname === '/api/submit' && req.method === 'POST')
        return await handleSubmit(req, env);
      if (url.pathname === '/api/hello' && req.method === 'POST')
        return await handleHello(req, env);
      if (url.pathname === '/api/clients') return await handleClients(env);
      if (url.pathname === '/api/leaderboard') return await handleLeaderboard(url, env);
      if (url.pathname === '/api/rares') return await handleRareLog(url, env);
      if (url.pathname === '/api/stats') return await handleStats(env);
      if (url.pathname === '/' || url.pathname === '/api')
        return json({
          service: 'levelpace',
          routes: ['/api/stats', '/api/leaderboard', '/api/rares', '/api/enrol', '/api/submit', '/api/hello', '/api/clients'],
          board: 'https://monscorps.github.io/levelpace',
        });
      return json({ error: 'not found' }, 404);
    } catch (err) {
      return json({ error: 'server error', detail: String(err && err.message) }, 500);
    }
  },
};
