// Gemeinsamer Zugang zu Supabase für töricht live.
(function () {
  'use strict';

  var cfg = window.TOERICHT_LIVE;
  var TL = {
    client: null,

    // hostAuth: true nur auf Host-Seiten (Login bleibt im Browser gespeichert).
    init: function (options) {
      var hostAuth = !!(options && options.hostAuth);
      TL.client = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
        auth: {
          persistSession: hostAuth,
          autoRefreshToken: hostAuth,
          detectSessionInUrl: false
        }
      });
      return TL.client;
    },

    // Ruft eine Datenbank-Funktion auf. Wirft bei Netzwerk-/HTTP-Fehlern und
    // Timeout; fachliche Fehler kommen als { ok: false, error } zurück.
    rpc: function (name, args, timeoutMs) {
      var ctrl = new AbortController();
      var timer = setTimeout(function () { ctrl.abort(); }, timeoutMs || 8000);
      return TL.client.rpc(name, args).abortSignal(ctrl.signal).then(function (res) {
        clearTimeout(timer);
        if (res.error) throw res.error;
        return res.data;
      }, function (err) {
        clearTimeout(timer);
        throw err;
      });
    }
  };

  // Baut DOM-Knoten; Texte landen immer als Textknoten, nie als HTML.
  TL.h = function (tag, props) {
    var el = document.createElement(tag);
    if (props) {
      Object.keys(props).forEach(function (k) {
        var v = props[k];
        if (k === 'class') el.className = v;
        else if (k.indexOf('on') === 0) el.addEventListener(k.slice(2), v);
        else if (v === true) el.setAttribute(k, '');
        else if (v !== false && v != null) el.setAttribute(k, v);
      });
    }
    for (var i = 2; i < arguments.length; i++) TL.append(el, arguments[i]);
    return el;
  };

  TL.append = function (el, child) {
    if (child == null || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { TL.append(el, c); }); return; }
    el.appendChild(child.nodeType ? child : document.createTextNode(String(child)));
  };

  TL.show = function (root) {
    var frag = document.createDocumentFragment();
    TL.append(frag, Array.prototype.slice.call(arguments, 1));
    root.replaceChildren(frag);
  };

  TL.formatTime = function (ms, lang) {
    return (ms / 1000).toLocaleString(lang || 'de', {
      minimumFractionDigits: 1, maximumFractionDigits: 1
    }) + ' s';
  };

  TL.IMAGE_BUCKET = 'quiz-images';

  // Öffentliche Adresse eines Bildes im Storage.
  TL.imageUrl = function (path) {
    return cfg.supabaseUrl + '/storage/v1/object/public/' + TL.IMAGE_BUCKET + '/' + path;
  };

  // Name der kleinen Variante fürs Handy: <uuid>.<ext> -> <uuid>_m.<ext>
  TL.mobileImage = function (path) {
    return path.replace(/\.([a-z]+)$/, '_m.$1');
  };

  // 0–6 Bilder, nie verzerrt oder beschnitten (object-fit: contain im CSS).
  // Die Klasse is-<anzahl> wählt das Raster.
  TL.imageRow = function (paths, className) {
    if (!paths || !paths.length) return null;
    return TL.h('div', { class: className + ' is-' + paths.length },
      paths.map(function (p) { return TL.h('img', { src: TL.imageUrl(p), alt: '' }); }));
  };

  // Farbstufen der Auflösung, gleiche Regel wie get_state in der Datenbank:
  // best = höchste positive Punktzahl, good = positiv darunter, bad = 0 oder negativ.
  TL.tiers = function (pointsList) {
    var max = Math.max.apply(null, pointsList);
    return pointsList.map(function (p) {
      return p > 0 && p === max ? 'best' : p > 0 ? 'good' : 'bad';
    });
  };

  // Zusätzlich zur Farbe ein Zeichen, damit die Auflösung nicht nur an der Farbe hängt.
  TL.TIER_MARKS = { best: '✓', good: '○', bad: '✕' };

  // Für Host-Seiten: true, wenn ein Login besteht und der Account Host ist.
  TL.checkHost = function () {
    return TL.client.auth.getSession().then(function (res) {
      if (!res.data || !res.data.session) return false;
      return TL.rpc('is_host', {}).then(function (isHost) { return isHost === true; });
    });
  };

  window.TL = TL;
})();
