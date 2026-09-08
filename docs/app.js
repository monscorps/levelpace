/* LevelPace leaderboard — no framework, no build step. */

(function () {
  "use strict";

  // WarcraftLogs bands. Kept in lockstep with Parse.BANDS in the addon and
  // with the CSS custom properties; changing one means changing all three.
  var BANDS = [
    { min: 100, css: "var(--q-artifact)",  name: "artifact"  },
    { min: 99,  css: "var(--q-pink)",      name: "astounding"},
    { min: 95,  css: "var(--q-legendary)", name: "legendary" },
    { min: 75,  css: "var(--q-epic)",      name: "epic"      },
    { min: 50,  css: "var(--q-rare)",      name: "rare"      },
    { min: 25,  css: "var(--q-uncommon)",  name: "uncommon"  },
    { min: 0,   css: "var(--q-common)",    name: "common"    }
  ];

  function band(pct) {
    if (pct === null || pct === undefined) return { css: "var(--q-common)", name: "unranked" };
    for (var i = 0; i < BANDS.length; i++) if (pct >= BANDS[i].min) return BANDS[i];
    return BANDS[BANDS.length - 1];
  }

  var boardEl = document.getElementById("board");
  var state = { view: "overall", level: null };

  // ---- helpers -------------------------------------------------------------

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  }

  function fmt(n, dp) {
    if (n === null || n === undefined || isNaN(n)) return "—";
    return Number(n).toLocaleString(undefined, {
      minimumFractionDigits: dp || 0, maximumFractionDigits: dp || 0
    });
  }

  function minutes(m) {
    if (m === null || m === undefined) return "—";
    if (m < 60) return Math.round(m) + "m";
    return Math.floor(m / 60) + "h " + Math.round(m % 60) + "m";
  }

  // Static mode: the same page is served two ways.
  //
  //   live   -- by levelpace_server.py, which answers /api/* directly
  //   Pages  -- as flat files, where there is no server to answer anything
  //
  // The publisher injects window.LEVELPACE_STATIC and writes the same
  // responses out as .json files, so the only thing that changes is how a
  // path is resolved. A query string becomes part of the filename, because
  // GitHub Pages cannot vary a response on one.
  var STATIC = (typeof window !== "undefined" && window.LEVELPACE_STATIC === true);

  function resolve(path) {
    if (!STATIC) return path;
    var q = path.indexOf("?");
    var base = q === -1 ? path : path.slice(0, q);
    var query = q === -1 ? "" : path.slice(q + 1);
    var name = base.replace(/^\/api\//, "");
    var m = /(?:^|&)level=(\d+)/.exec(query);
    if (m) name = "level-" + m[1];
    return "api/" + name + ".json";
  }

  function api(path) {
    return fetch(resolve(path), { headers: { "Accept": "application/json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      });
  }

  // ---- rendering -----------------------------------------------------------

  function header(cols) {
    var row = el("div", "row head");
    row.style.setProperty("--cols", cols.length);
    row.appendChild(el("div", "rank", "#"));
    row.appendChild(el("div", "who", "player"));
    cols.forEach(function (c) {
      row.appendChild(el("div", "num " + (c.cls || ""), c.label));
    });
    return row;
  }

  // Flags mean "a human should look at this", never "this is a cheater".
  // Shown rather than hidden, because quietly dropping entries would make the
  // board look clean while telling nobody anything.
  var FLAG_TEXT = {
    "pace": "implausibly fast",
    "rewritten": "elapsed time was edited after the level was recorded",
    "kills-without-xp": "kills recorded but no kill XP",
    "xp-without-kills": "kill XP recorded but no kills",
    "quests-without-xp": "quests recorded but no quest XP",
    "no-xp": "no XP recorded at all",
    "kill-rate": "more kills than seconds in the level",
    "corpse-exceeds-level": "corpse-run time longer than the level",
    "corpse-without-death": "corpse-run time with no deaths"
  };

  function personCell(e) {
    var who = el("div", "who");
    var nameRow = el("div", "name");
    nameRow.appendChild(document.createTextNode(e.display || "Unknown"));
    if (e.flags && e.flags.length) {
      var badge = el("span", "flagbadge", "?");
      badge.title = "Needs review: " + e.flags.map(function (f) {
        return FLAG_TEXT[f] || f;
      }).join("; ");
      nameRow.appendChild(badge);
    }
    who.appendChild(nameRow);
    var bits = [];
    if (e.realm) bits.push(e.realm);
    if (e.class) bits.push(e.class.toLowerCase());
    if (e.faction) bits.push(e.faction.toLowerCase());
    if (e.level) bits.push("lvl " + e.level);
    if (bits.length) {
      var meta = el("div", "meta");
      bits.forEach(function (b, i) {
        if (i) meta.appendChild(el("span", "sep", "/"));
        meta.appendChild(document.createTextNode(b));
      });
      who.appendChild(meta);
    }
    return who;
  }

  function parseCell(pct, label) {
    var b = band(pct);
    var d = el("div", "parse");
    d.style.setProperty("--c", b.css);
    d.textContent = (pct === null || pct === undefined) ? "—" : Math.round(pct);
    var s = el("small", null, (pct === null || pct === undefined) ? "unranked" : (label || b.name));
    d.appendChild(s);
    return d;
  }

  function makeRow(e, pct, cells, i) {
    var b = band(pct);
    var row = el("div", "row");
    row.style.setProperty("--cols", cells.length);
    row.style.setProperty("--c", b.css);
    row.style.setProperty("--fill", (pct === null || pct === undefined ? 0 : pct) + "%");
    row.style.animationDelay = Math.min(i * 22, 500) + "ms";
    row.appendChild(el("div", "rank", e.rank));
    row.appendChild(personCell(e));
    cells.forEach(function (c) { row.appendChild(c); });
    return row;
  }

  function empty(title, lines, hint) {
    var box = el("div", "empty");
    box.appendChild(el("h2", null, title));
    lines.forEach(function (html) {
      var p = el("p");
      p.innerHTML = html;
      box.appendChild(p);
    });
    if (hint) {
      var h = el("p", "hint");
      h.innerHTML = hint;
      box.appendChild(h);
    }
    return box;
  }

  // ---- views ---------------------------------------------------------------

  function renderOverall(entries) {
    boardEl.innerHTML = "";
    if (!entries.length) {
      boardEl.appendChild(empty(
        "No one has posted a level yet.",
        ["This board only ever shows people running LevelPace with sharing switched on — " +
          "there is no way to pull levelling data out of WoW itself, so nothing appears " +
          "until someone measures it in game.",
         "In game: <code>/lp</code> &rarr; Leaderboard &rarr; <em>Share my levelling stats</em>. " +
         "Then log out, and run <code>levelpace_upload.py</code>."],
        "A level only appears once it is <em>completed</em> — a level in progress has no pace to rank."
      ));
      return;
    }
    boardEl.appendChild(header([
      { label: "levels" }, { label: "best" }, { label: "parse" }
    ]));
    entries.forEach(function (e, i) {
      boardEl.appendChild(makeRow(e, e.parse, [
        el("div", "num dim", fmt(e.levels)),
        el("div", "num dim", e.best === null || e.best === undefined ? "—" : Math.round(e.best)),
        parseCell(e.parse)
      ], i));
    });
  }

  function renderLevel(entries, level) {
    boardEl.innerHTML = "";
    if (!entries.length) {
      boardEl.appendChild(empty(
        "Nothing logged at level " + level + ".",
        ["Pick another level, or be the first to finish this one."]
      ));
      return;
    }
    boardEl.appendChild(header([
      { label: "time" }, { label: "lvl/hr" }, { label: "parse" }
    ]));
    entries.forEach(function (e, i) {
      boardEl.appendChild(makeRow(e, e.parse, [
        el("div", "num dim", minutes(e.minutes)),
        el("div", "num dim", fmt(e.levelsPerHour, 2)),
        parseCell(e.parse)
      ], i));
    });
    if (entries.length === 1) {
      boardEl.appendChild(empty(
        "Only one entry here.",
        ["A percentile needs someone to compare against, so this one shows as <em>unranked</em> " +
         "rather than being called a 100."]
      ));
    }
  }

  function renderTwinks(entries) {
    boardEl.innerHTML = "";
    if (!entries.length) {
      boardEl.appendChild(empty(
        "No twink data yet.",
        ["This board wants weekly kills, item level, lifetime kills, deaths and your top three nemeses.",
         "The addon does not collect any of that <em>yet</em> — the PvP, item-level and " +
         "combat-log APIs are being verified against the 3.3.5a client before anything is built on them."],
        "The server already accepts and stores it, so the board lights up the moment the addon starts sending."
      ));
      return;
    }
    boardEl.appendChild(header([
      { label: "wk kills" }, { label: "ilvl" }, { label: "lifetime" },
      { label: "deaths" }, { label: "k/d" }, { label: "nemesis" }
    ]));
    entries.forEach(function (e, i) {
      var nem = el("div", "nemesis");
      (e.nemesis || []).slice(0, 3).forEach(function (n) {
        var s = el("span");
        s.appendChild(el("b", null, n.name || "?"));
        s.appendChild(document.createTextNode(" ×" + (n.count || 0)));
        nem.appendChild(s);
      });
      if (!nem.childNodes.length) nem.appendChild(el("span", null, "—"));

      // Twinks rank on kills, so the colour follows weekly kills relative to
      // the leader rather than a levelling parse.
      var top = entries[0].weekly_kills || 1;
      var pct = Math.min(100, Math.round((e.weekly_kills || 0) / top * 100));

      boardEl.appendChild(makeRow(e, pct, [
        el("div", "num", fmt(e.weekly_kills)),
        el("div", "num dim", e.item_level ? fmt(e.item_level, 1) : "—"),
        el("div", "num dim hide-sm", fmt(e.lifetime_kills)),
        el("div", "num dim hide-sm", fmt(e.deaths)),
        el("div", "num hide-sm", e.kd === null || e.kd === undefined ? "—" : fmt(e.kd, 2)),
        nem
      ], i));
    });
  }

  // ---- loading -------------------------------------------------------------

  function loadVitals() {
    api("/api/stats").then(function (s) {
      document.getElementById("v-players").textContent = fmt(s.players);
      document.getElementById("v-levels").textContent = fmt(s.levels);
      document.getElementById("v-pvp").textContent = fmt(s.pvp);
      showSnapshotAge(s.published);
      // The publisher derives the releases URL from the Pages URL, so this
      // stays correct if the repo is ever renamed or moved.
      var get = document.getElementById("getit");
      if (get && s.downloadUrl) {
        get.href = s.downloadUrl;
        if (s.addonVersion) get.firstChild.nodeValue = "Get the addon " + s.addonVersion + " ";
      }
    }).catch(function () {});
  }

  function loadLevels() {
    return api("/api/baseline").then(function (b) {
      var sel = document.getElementById("level-select");
      var have = Object.keys(b.byLevel || {}).map(Number).sort(function (a, c) { return a - c; });
      sel.innerHTML = "";
      if (!have.length) {
        sel.appendChild(new Option("—", ""));
        return null;
      }
      have.forEach(function (l) { sel.appendChild(new Option(l, l)); });
      if (state.level === null || have.indexOf(state.level) === -1) state.level = have[0];
      sel.value = String(state.level);
      return state.level;
    });
  }

  function load() {
    boardEl.innerHTML = "";
    boardEl.appendChild(empty("Loading…", []));
    loadVitals();

    if (state.view === "overall") {
      api("/api/leaderboard").then(function (d) { renderOverall(d.entries || []); })
        .catch(failed);
    } else if (state.view === "level") {
      loadLevels().then(function (level) {
        if (level === null) { renderLevel([], "—"); return; }
        return api("/api/leaderboard?level=" + level).then(function (d) {
          renderLevel(d.entries || [], level);
        });
      }).catch(failed);
    } else {
      api("/api/twinks").then(function (d) { renderTwinks(d.entries || []); })
        .catch(failed);
    }
  }

  function failed(err) {
    boardEl.innerHTML = "";
    boardEl.appendChild(empty(
      STATIC ? "That board has not been published yet." : "Could not reach the server.",
      ["<code>" + String(err.message || err) + "</code>",
       STATIC
         ? "This is a published snapshot. Whoever hosts it needs to run the publish step again."
         : "Is <code>levelpace_server.py</code> running?"]
    ));
  }

  // A published snapshot is a point in time, and saying so is the difference
  // between "quiet week" and "nobody has updated this since March".
  function showSnapshotAge(fetched) {
    if (!STATIC || !fetched) return;
    var el2 = document.getElementById("snapshot");
    if (!el2) return;
    var mins = Math.max(0, (Date.now() / 1000 - fetched) / 60);
    var txt;
    if (mins < 90) txt = Math.round(mins) + " min ago";
    else if (mins < 60 * 48) txt = Math.round(mins / 60) + " hours ago";
    else txt = Math.round(mins / 1440) + " days ago";
    el2.textContent = "snapshot published " + txt;
    el2.hidden = false;
  }

  // ---- wiring --------------------------------------------------------------

  Array.prototype.forEach.call(document.querySelectorAll(".tab"), function (t) {
    t.addEventListener("click", function () {
      Array.prototype.forEach.call(document.querySelectorAll(".tab"), function (o) {
        o.classList.remove("is-active");
        o.setAttribute("aria-selected", "false");
      });
      t.classList.add("is-active");
      t.setAttribute("aria-selected", "true");
      state.view = t.dataset.view;
      document.getElementById("lvlpick").hidden = (state.view !== "level");
      load();
    });
  });

  document.getElementById("level-select").addEventListener("change", function (e) {
    state.level = Number(e.target.value);
    load();
  });
  document.getElementById("refresh").addEventListener("click", load);

  load();
})();
