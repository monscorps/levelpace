/* LevelPace — the board. No framework, no build step.
 *
 * Reads the live Worker API directly (CORS is open on it for exactly this).
 * The API address is looked up from api/config.json rather than hardcoded, so
 * moving the API does not require editing this file.
 */
(function () {
  "use strict";

  var FALLBACK_API = "https://levelpace.andustemme.workers.dev";
  var api = null;

  var BAND_VAR = {
    grey: "--q-common", green: "--q-uncommon", blue: "--q-rare",
    purple: "--q-epic", orange: "--q-legendary", pink: "--q-pink",
    gold: "--q-artifact"
  };
  // 3.3.5a class colours (Constants.lua). A colour scheme, not a texture.
  var CLASS_COLOUR = {
    HUNTER: "#abd473", WARLOCK: "#9482c9", PRIEST: "#ffffff", PALADIN: "#f58cba",
    MAGE: "#69ccf0", ROGUE: "#fff569", DRUID: "#ff7d0a", SHAMAN: "#0070de",
    WARRIOR: "#c79c6e", DEATHKNIGHT: "#c41f3b"
  };
  var CLASS_SHORT = {
    HUNTER: "Hunter", WARLOCK: "Warlock", PRIEST: "Priest", PALADIN: "Paladin",
    MAGE: "Mage", ROGUE: "Rogue", DRUID: "Druid", SHAMAN: "Shaman",
    WARRIOR: "Warrior", DEATHKNIGHT: "Death Knight"
  };

  var VIEWS = {
    levelling: {
      path: "/api/leaderboard?board=levelling&limit=100", label: "lvl / hr",
      sub: "Levels per hour — deaths, corpse runs and bank time included. Colour is your percentile among everyone here.",
      empty: ["Nobody has", "timed a level", "yet"], hint: "Finish one level with sharing on and you are #1."
    },
    pvp: {
      path: "/api/leaderboard?board=pvp&limit=100", label: "honor kills",
      sub: "Lifetime honorable kills, straight from the server. Needs the PvP sharing tick.",
      empty: ["No one has", "shared PvP", "yet"], hint: "Tick “Also share PvP” on the skull menu, then /reload."
    },
    rares: {
      path: "/api/leaderboard?board=rares&limit=100", label: "rares",
      sub: "Rare kills credited to you — your killing blow, or one landed next to you.",
      empty: ["No rare", "has died", "yet"], hint: "420 rares are catalogued. Go find one."
    },
    rarelog: {
      path: "/api/rares?limit=80", label: "",
      sub: "Every rare kill reported, newest first.",
      empty: ["Nothing in", "the log", "yet"], hint: "The first kill lands here within a minute of an upload."
    }
  };

  var view = "levelling";
  var cache = {};
  var updatedAt = null;

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function num(n) {
    if (n == null) return "—";
    return Number(n).toLocaleString(undefined, { maximumFractionDigits: 2 });
  }
  function bandVar(band) { return "var(" + (BAND_VAR[band] || "--q-common") + ")"; }
  function classColour(c) { return CLASS_COLOUR[c] || "var(--text)"; }
  function ago(ts) {
    if (!ts) return "—";
    var s = Math.max(0, Math.round(Date.now() / 1000 - ts));
    if (s < 60) return s + "s ago";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h ago";
    return Math.floor(s / 86400) + "d ago";
  }

  function live(ok, text) {
    var d = $("dot"), t = $("livetext");
    if (d) d.className = "livedot " + (ok ? "ok" : "bad");
    if (t) t.textContent = text;
  }

  function getJSON(url) {
    return fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error(r.status + " from " + url); return r.json(); });
  }
  function resolveApi() {
    if (api) return Promise.resolve(api);
    return getJSON("api/config.json")
      .then(function (c) { api = (c && c.uploadUrl) || FALLBACK_API; return api; })
      .catch(function () { api = FALLBACK_API; return api; });
  }
  function call(path) {
    return resolveApi().then(function (base) { return getJSON(base.replace(/\/+$/, "") + path); });
  }

  // ---- pieces ---------------------------------------------------------------

  function chips(e) {
    var out = "";
    if (e.class) out += '<span class="chip chip-class" style="--cc:' + classColour(e.class) + '">' + esc(CLASS_SHORT[e.class] || e.class) + "</span>";
    if (e.faction) out += '<span class="chip chip-' + (e.faction === "Horde" ? "H" : "A") + '">' + (e.faction === "Horde" ? "Horde" : "Alliance") + "</span>";
    if (e.level) out += '<span class="chip">lvl ' + esc(e.level) + "</span>";
    if (e.realm) out += '<span class="chip">' + esc(e.realm) + "</span>";
    return out;
  }

  function pctText(e) {
    return e.percentile == null ? "no rival yet" : Math.round(e.percentile) + "%";
  }

  function podium(entries, label) {
    var html = "";
    for (var i = 0; i < 3; i++) {
      var e = entries[i];
      if (!e) {
        html += '<div class="pod is-open pod-' + (i + 1) + '">' +
          '<div class="pod-rank">' + (i + 1) + "</div>" +
          "<p>" + (i === 0 ? "Open. Be the first." : "This spot is open.") + "</p></div>";
        continue;
      }
      var c = bandVar(e.band);
      html += '<div class="pod pod-' + (i + 1) + '" style="--c:' + (e.band ? c : "var(--dim)") + '">' +
        '<div class="pod-rank">' + (i + 1) + "<small>" + ["first", "second", "third"][i] + "</small></div>" +
        '<div class="pod-who"><div class="pod-name who" style="--cc:' + classColour(e.class) + '">' + esc(e.name) + "</div>" +
        '<div class="pod-meta">' + chips(e) + "</div></div>" +
        '<div class="pod-metric"><b>' + num(e.metric) + "</b><span>" + esc(label) + "</span></div>" +
        '<div class="pod-meta">' +
          (e.band ? '<span class="chip chip-band" style="--c:' + c + '">' + esc(e.band) + " · " + pctText(e) + "</span>"
                  : '<span class="chip">' + pctText(e) + "</span>") +
          (e.levels ? '<span class="chip">' + esc(e.levels) + " levels</span>" : "") +
        "</div></div>";
    }
    return '<div class="podium">' + html + "</div>";
  }

  function table(entries, label) {
    if (entries.length <= 3) return "";
    var top = entries[0].metric || 0;
    var rows = entries.slice(3).map(function (e, i) {
      var c = e.band ? bandVar(e.band) : "var(--faint)";
      var w = top > 0 ? Math.max(2, (e.metric / top) * 100) : 0;
      return '<tr style="animation-delay:' + Math.min(i * 30, 600) + 'ms">' +
        '<td class="rank">' + (i + 4) + "</td>" +
        '<td><span class="name who" style="--cc:' + classColour(e.class) + '">' + esc(e.name) + "</span>" +
          '<span class="meta">' + [CLASS_SHORT[e.class], e.level ? "lvl " + e.level : null, e.realm].filter(Boolean).map(esc).join(" · ") + "</span></td>" +
        '<td class="barcell"><span class="bar"><i style="--w:' + w + "%;--c:" + c + '"></i></span></td>' +
        '<td class="r"><b>' + num(e.metric) + "</b></td>" +
        '<td class="r pct" style="--c:' + c + '">' + pctText(e) + "</td>" +
        '<td class="r band" style="--c:' + c + '">' + esc(e.band || "") + "</td>" +
        "</tr>";
    }).join("");
    return '<table class="ranktable"><thead><tr><th class="rank">#</th><th>Player</th>' +
      '<th class="barcell">Standing</th><th class="r">' + esc(label) + '</th><th class="r">Percentile</th><th class="r band">Band</th>' +
      "</tr></thead><tbody>" + rows + "</tbody></table>";
  }

  function empty(v) {
    return '<div class="empty"><h3>' + esc(v.empty[0]) + " <span>" + esc(v.empty[1]) + "</span><br>" + esc(v.empty[2]) + "</h3>" +
      "<p>" + esc(v.hint) + "</p>" +
      '<a class="btn btn-ghost" href="#join">How to get on</a></div>';
  }

  function renderBoard(entries, v) {
    if (!entries.length) return empty(v);
    return podium(entries, v.label) + table(entries, v.label);
  }

  function renderRareLog(kills, v) {
    if (!kills.length) return empty(v);
    return '<ol class="killlog">' + kills.map(function (k, i) {
      return '<li style="animation-delay:' + Math.min(i * 25, 500) + 'ms"><span class="skull">☠</span>' +
        '<span class="what"><b>' + esc(k.by) + "</b> killed <b>" + esc(k.name || "#" + k.npc) + "</b>" +
          ' <span class="how">' + (k.witnessed ? "witnessed" : "killing blow") + (k.learned ? " · learned" : "") + "</span></span>" +
        '<span class="when">' + esc(ago(k.at)) + "</span></li>";
    }).join("") + "</ol>";
  }

  // ---- loading ----------------------------------------------------------------

  function show(html) {
    var b = $("board");
    if (!b) return;
    b.classList.remove("is-drawn");
    b.innerHTML = html;
    // Next frame, so the bars animate from zero.
    requestAnimationFrame(function () { requestAnimationFrame(function () { b.classList.add("is-drawn"); }); });
  }

  function setCount(which, n) {
    var el = $("n-" + which);
    if (el) el.textContent = n > 0 ? String(n) : "";
  }

  function load(which, force) {
    view = which;
    var v = VIEWS[which];
    var sub = $("board-sub");
    if (sub) sub.textContent = v.sub;
    if (!force && cache[which]) { show(cache[which]); return; }
    show('<div class="empty"><p>Loading…</p></div>');

    var p = which === "rarelog"
      ? call(v.path).then(function (d) { var k = d.kills || []; setCount(which, k.length); return renderRareLog(k, v); })
      : call(v.path).then(function (d) { var e = d.entries || []; setCount(which, e.length); return renderBoard(e, v); });

    p.then(function (html) {
      cache[which] = html;
      show(html);
    }).catch(function (err) {
      live(false, "board unreachable");
      show('<div class="empty"><h3>Could not <span>reach</span> the board</h3><p>' +
        esc(err && err.message ? err.message : String(err)) + "</p><p>The addon still works; only this page needs the API.</p></div>");
    });
  }

  function loadVitals() {
    call("/api/stats").then(function (s) {
      live(true, "live");
      if ($("v-players")) $("v-players").textContent = num(s.characters || 0);
      if ($("v-levels")) $("v-levels").textContent = num(s.levels || 0);
      if ($("v-rares")) $("v-rares").textContent = num(s.rareKills || 0);
      updatedAt = s.updated || Math.round(Date.now() / 1000);
      tickUpdated();
    }).catch(function () { live(false, "API down"); });
  }

  function tickUpdated() {
    var el = $("v-updated");
    if (el) el.textContent = ago(updatedAt);
  }

  // Warm the other tabs' counts so the badges are right before you click.
  function warmCounts() {
    Object.keys(VIEWS).forEach(function (k) {
      if (k === view) return;
      call(VIEWS[k].path).then(function (d) {
        setCount(k, (d.entries || d.kills || []).length);
      }).catch(function () {});
    });
  }

  // ---- wiring -----------------------------------------------------------------

  document.addEventListener("DOMContentLoaded", function () {
    var tabs = document.querySelectorAll(".tab[data-view]");
    Array.prototype.forEach.call(tabs, function (t) {
      t.addEventListener("click", function () {
        Array.prototype.forEach.call(tabs, function (o) { o.classList.remove("is-active"); o.setAttribute("aria-selected", "false"); });
        t.classList.add("is-active"); t.setAttribute("aria-selected", "true");
        load(t.getAttribute("data-view"), false);
      });
    });
    var r = $("refresh");
    if (r) r.addEventListener("click", function () { cache = {}; loadVitals(); load(view, true); warmCounts(); });

    loadVitals();
    load("levelling", false);
    warmCounts();
    setInterval(tickUpdated, 10000);
    setInterval(function () { cache = {}; loadVitals(); load(view, true); }, 120000);
  });
})();
