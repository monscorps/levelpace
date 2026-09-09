/* LevelPace leaderboard — no framework, no build step.
 *
 * This used to read static JSON files published by a Python server running on
 * a Mac at home. That server is retired, so those files stopped updating and
 * the board was permanently frozen at zero while looking perfectly healthy.
 * It now reads the live API directly; CORS is open on it for exactly this.
 *
 * The upload address is looked up from api/config.json rather than hardcoded,
 * so moving the API again does not require editing this file or asking anyone
 * to re-download anything.
 */

(function () {
  "use strict";

  var FALLBACK_API = "https://levelpace.andustemme.workers.dev";
  var api = null;

  var BANDS = ["grey", "green", "blue", "purple", "orange", "pink", "gold"];
  var BAND_VAR = {
    grey: "--q-common", green: "--q-uncommon", blue: "--q-rare",
    purple: "--q-epic", orange: "--q-legendary", pink: "--q-pink",
    gold: "--q-artifact"
  };

  var view = "levelling";
  var cache = {};

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function num(n) {
    if (n == null) return "—";
    return Number(n).toLocaleString(undefined, { maximumFractionDigits: 2 });
  }

  function bandColour(band) {
    var v = BAND_VAR[band] || "--q-common";
    return getComputedStyle(document.documentElement).getPropertyValue(v).trim() || "#6c6f75";
  }

  function live(ok, text) {
    var d = $("dot"), t = $("livetext");
    if (d) d.className = "livedot " + (ok ? "ok" : "bad");
    if (t) t.textContent = text;
  }

  function getJSON(url) {
    return fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error(r.status + " from " + url);
        return r.json();
      });
  }

  // The API address lives beside the board so it can move without a redeploy.
  function resolveApi() {
    if (api) return Promise.resolve(api);
    return getJSON("api/config.json")
      .then(function (c) { api = (c && c.uploadUrl) || FALLBACK_API; return api; })
      .catch(function () { api = FALLBACK_API; return api; });
  }

  function call(path) {
    return resolveApi().then(function (base) {
      return getJSON(base.replace(/\/+$/, "") + path);
    });
  }

  // ---- rendering ----------------------------------------------------------

  function emptyState(what) {
    return '<div class="empty-board">' +
      "<p><strong>Nobody is on this board yet.</strong> " + esc(what) + "</p>" +
      "<p>To be the first: install the addon, tick <em>Share to leaderboard</em> " +
      "on the minimap menu, type <code>/reload</code>, and run the companion.</p>" +
      "</div>";
  }

  function renderBoard(entries, valueLabel, emptyWhat) {
    if (!entries || !entries.length) return emptyState(emptyWhat);
    var top = entries[0].metric || 0;
    var rows = entries.map(function (e, i) {
      var pct = e.percentile;
      var colour = bandColour(e.band);
      var fill = top > 0 ? Math.max(2, (e.metric / top) * 100) : 0;
      return '<tr>' +
        '<td class="rank">' + (i + 1) + "</td>" +
        "<td><span class=\"who\">" + esc(e.name) + "</span>" +
          (e.realm ? ' <span class="realm">' + esc(e.realm) + "</span>" : "") +
          (e.level ? ' <span class="realm">lvl ' + esc(e.level) + "</span>" : "") +
        "</td>" +
        '<td class="barcell"><span class="bar"><i style="width:' + fill +
          "%;background:" + colour + '"></i></span></td>' +
        '<td class="r">' + num(e.metric) + "</td>" +
        '<td class="r" style="color:' + colour + '">' +
          (pct == null ? "—" : Math.round(pct) + "%") + "</td>" +
        '<td class="r band" style="color:' + colour + '">' + esc(e.band || "—") + "</td>" +
        "</tr>";
    }).join("");

    return '<table class="ranktable"><thead><tr>' +
      '<th class="rank">#</th><th>Player</th><th>Standing</th>' +
      '<th class="r">' + esc(valueLabel) + "</th>" +
      '<th class="r">Percentile</th><th class="r">Band</th>' +
      "</tr></thead><tbody>" + rows + "</tbody></table>";
  }

  function renderRareLog(kills) {
    if (!kills || !kills.length) {
      return emptyState("No rare kills have been reported.");
    }
    var rows = kills.map(function (k) {
      var when = new Date(k.at * 1000);
      return "<tr>" +
        '<td class="who">' + esc(k.name || "#" + k.npc) + "</td>" +
        "<td>" + esc(k.by) + "</td>" +
        "<td>" + esc(when.toLocaleString()) + "</td>" +
        '<td class="r realm">' + (k.witnessed ? "witnessed" : "killing blow") +
          (k.learned ? " · learned" : "") + "</td>" +
        "</tr>";
    }).join("");
    return '<table class="ranktable"><thead><tr>' +
      "<th>Rare</th><th>Killed by</th><th>When</th><th class=\"r\">How</th>" +
      "</tr></thead><tbody>" + rows + "</tbody></table>";
  }

  // ---- loading ------------------------------------------------------------

  var VIEWS = {
    levelling: { path: "/api/leaderboard?board=levelling", label: "Levels/hr",
                 empty: "No levelling times have been uploaded." },
    pvp:       { path: "/api/leaderboard?board=pvp", label: "Honorable kills",
                 empty: "No battleground stats have been uploaded." },
    rares:     { path: "/api/leaderboard?board=rares", label: "Rares killed",
                 empty: "No rare kills have been uploaded." }
  };

  function show(html) {
    var b = $("board");
    if (b) b.innerHTML = html;
  }

  function load(which, force) {
    view = which;
    if (!force && cache[which]) { show(cache[which]); return; }
    show('<div class="empty-board"><p>Loading…</p></div>');

    var p;
    if (which === "rarelog") {
      p = call("/api/rares?limit=60").then(function (d) {
        return renderRareLog(d.kills || []);
      });
    } else {
      var v = VIEWS[which];
      p = call(v.path).then(function (d) {
        return renderBoard(d.entries || [], v.label, v.empty);
      });
    }

    p.then(function (html) {
      cache[which] = html;
      show(html);
      var snap = $("snapshot");
      if (snap) {
        snap.hidden = false;
        snap.textContent = "updated " + new Date().toLocaleTimeString();
      }
    }).catch(function (err) {
      live(false, "cannot reach the board API");
      show('<div class="empty-board"><p><strong>Could not reach the board.</strong> ' +
        reason(err) + "</p><p>The addon still works; only this page needs the API.</p></div>");
    });
  }

  function reason(err) {
    return esc(err && err.message ? err.message : String(err));
  }

  function loadVitals() {
    call("/api/stats").then(function (s) {
      live(true, "board is live");
      if ($("v-players")) $("v-players").textContent = s.characters || 0;
      if ($("v-levels")) $("v-levels").textContent = s.levels || 0;
      if ($("v-rares")) $("v-rares").textContent = s.rareKills || 0;
    }).catch(function () {
      live(false, "board API is not responding");
    });
  }

  // ---- wiring -------------------------------------------------------------

  document.addEventListener("DOMContentLoaded", function () {
    var tabs = document.querySelectorAll(".tab");
    Array.prototype.forEach.call(tabs, function (t) {
      t.addEventListener("click", function () {
        Array.prototype.forEach.call(tabs, function (o) {
          o.classList.remove("is-active");
          o.setAttribute("aria-selected", "false");
        });
        t.classList.add("is-active");
        t.setAttribute("aria-selected", "true");
        load(t.getAttribute("data-view"), false);
      });
    });

    var r = $("refresh");
    if (r) r.addEventListener("click", function () {
      cache = {};
      loadVitals();
      load(view, true);
    });

    loadVitals();
    load("levelling", false);
  });
})();
