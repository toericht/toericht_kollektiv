// Spieler:innen-Ansicht für töricht live.
// Das Handy ist nur Controller: Bilder, Video und Ton laufen ausschließlich auf
// dem Presenter und werden hier weder geladen noch vom Server geliefert.
// Der Server ist die einzige Quelle des Spielstands: Diese Seite zeigt immer nur
// an, was get_state liefert. Realtime ist nur ein Signal zum Neuladen.
(function () {
  'use strict';

  var TL = window.TL;
  TL.init();

  var isDe = /^de/i.test(navigator.language || 'de');
  document.documentElement.lang = isDe ? 'de' : 'en';

  var T = isDe ? {
    codeTitle: 'mitspielen',
    codeText: 'gib den code ein, der auf der leinwand steht.',
    codeLabel: 'code',
    next: 'weiter',
    joinTitle: 'wie heißt du?',
    joinText: 'dein name erscheint später in der rangliste.',
    nickLabel: 'name',
    join: 'mitspielen',
    wasHere: 'ich war schon dabei',
    recoverTitle: 'wieder einsteigen',
    recoverText: 'frag den host nach einem code für dich. er gilt nur ein paar minuten.',
    recoverLabel: 'code vom host',
    recover: 'einsteigen',
    back: 'zurück',
    loading: 'lädt …',
    lobbyTitle: 'du bist dabei.',
    lobbyText: function (n) { return 'hi ' + n + '! gleich geht\'s los.'; },
    lobbyCount: function (n) { return n === 1 ? '1 person in der lobby' : n + ' personen in der lobby'; },
    question: function (a, b) { return 'frage ' + a + ' / ' + b; },
    poll: 'umfrage',
    top: 'meistgewählt',
    pickMany: function (n) { return 'du kannst bis zu ' + n + ' antworten wählen'; },
    send: 'absenden',
    sendChange: 'änderung absenden',
    saving: 'wird gespeichert …',
    saved: 'gespeichert ✓ – du kannst noch ändern.',
    unsent: 'noch nicht abgesendet.',
    closed: 'antworten sind geschlossen.',
    noAnswer: 'du hast diesmal nicht geantwortet.',
    tooLate: 'zu spät – die frage war schon geschlossen.',
    saveFailed: 'das hat nicht geklappt. bitte nochmal tippen.',
    results: 'so habt ihr geantwortet',
    slideTitle: 'schau auf die leinwand.',
    slideText: 'gleich geht\'s hier weiter.',
    mine: 'deine wahl',
    tier: { best: 'beste antwort', good: 'gibt punkte', bad: 'keine punkte' },
    standings: 'zwischenstand',
    final: 'endstand',
    place: function (r) { return 'platz ' + r; },
    points: function (p) { return p === 1 || p === -1 ? p + ' punkt' : p + ' punkte'; },
    ended: 'das spiel ist vorbei. danke fürs mitspielen!',
    removedTitle: 'du bist raus.',
    removedText: 'der host hat dich aus dem spiel entfernt.',
    offline: 'verbindung wird wiederhergestellt …',
    errNetwork: 'keine verbindung. bitte nochmal versuchen.',
    errNotFound: 'diesen code gibt es nicht.',
    errEnded: 'dieses spiel ist schon vorbei.',
    errLocked: 'der host lässt gerade niemanden mehr rein.',
    errFull: 'das spiel ist voll.',
    errNick: 'bitte gib einen namen ein (höchstens 24 zeichen).',
    errCode: 'der code stimmt nicht oder ist abgelaufen.',
    errUnknown: 'dieses gerät ist nicht mehr angemeldet. steig bitte neu ein.',
    errGeneric: 'etwas ist schiefgelaufen. bitte nochmal versuchen.'
  } : {
    codeTitle: 'join the game',
    codeText: 'enter the code shown on the screen.',
    codeLabel: 'code',
    next: 'next',
    joinTitle: 'what\'s your name?',
    joinText: 'your name will show up on the leaderboard later.',
    nickLabel: 'name',
    join: 'join',
    wasHere: 'i was already playing',
    recoverTitle: 'rejoin',
    recoverText: 'ask the host for a code for you. it only works for a few minutes.',
    recoverLabel: 'code from the host',
    recover: 'rejoin',
    back: 'back',
    loading: 'loading …',
    lobbyTitle: 'you\'re in.',
    lobbyText: function (n) { return 'hi ' + n + '! we\'re about to start.'; },
    lobbyCount: function (n) { return n === 1 ? '1 person in the lobby' : n + ' people in the lobby'; },
    question: function (a, b) { return 'question ' + a + ' / ' + b; },
    poll: 'poll',
    top: 'most picked',
    pickMany: function (n) { return 'you can pick up to ' + n + ' answers'; },
    send: 'submit',
    sendChange: 'submit change',
    saving: 'saving …',
    saved: 'saved ✓ – you can still change it.',
    unsent: 'not submitted yet.',
    closed: 'answers are closed.',
    noAnswer: 'you didn\'t answer this one.',
    tooLate: 'too late – the question was already closed.',
    saveFailed: 'that didn\'t work. please tap again.',
    results: 'how you all answered',
    slideTitle: 'look at the screen.',
    slideText: 'we\'ll continue here in a moment.',
    mine: 'your pick',
    tier: { best: 'best answer', good: 'scores points', bad: 'no points' },
    standings: 'standings',
    final: 'final ranking',
    place: function (r) { return 'place ' + r; },
    points: function (p) { return p === 1 || p === -1 ? p + ' point' : p + ' points'; },
    ended: 'the game is over. thanks for playing!',
    removedTitle: 'you\'re out.',
    removedText: 'the host removed you from the game.',
    offline: 'reconnecting …',
    errNetwork: 'no connection. please try again.',
    errNotFound: 'this code doesn\'t exist.',
    errEnded: 'this game is already over.',
    errLocked: 'the host isn\'t letting anyone in right now.',
    errFull: 'the game is full.',
    errNick: 'please enter a name (24 characters max).',
    errCode: 'that code is wrong or has expired.',
    errUnknown: 'this device is no longer signed in. please join again.',
    errGeneric: 'something went wrong. please try again.'
  };

  var app = document.getElementById('app');
  var banner = document.getElementById('conn-banner');
  banner.textContent = T.offline;

  // -------------------------------------------------------------------------
  // Helfer
  // -------------------------------------------------------------------------

  // Baut DOM-Knoten; Texte landen immer als Textknoten, nie als HTML.
  function h(tag, props) {
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
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }

  function append(el, child) {
    if (child == null || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { append(el, c); }); return; }
    el.appendChild(child.nodeType ? child : document.createTextNode(String(child)));
  }

  function show() {
    var frag = document.createDocumentFragment();
    append(frag, Array.prototype.slice.call(arguments));
    app.replaceChildren(frag);
  }

  function newToken() {
    var bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return Array.prototype.map.call(bytes, function (b) {
      return ('0' + b.toString(16)).slice(-2);
    }).join('');
  }

  function normalizeCode(v) {
    return (v || '').replace(/\s/g, '').toUpperCase();
  }

  function formatTime(ms) {
    return (ms / 1000).toLocaleString(isDe ? 'de' : 'en', {
      minimumFractionDigits: 1, maximumFractionDigits: 1
    }) + ' s';
  }

  function sameIds(a, b) {
    return a.length === b.length && a.slice().sort().join() === b.slice().sort().join();
  }

  // localStorage kann fehlen oder werfen (privater Modus); dann gilt nur der Speicher.
  var memory = {};
  var STORAGE_PREFIX = 'toericht-live:';

  function loadCreds(c) {
    var v = null;
    try { v = JSON.parse(localStorage.getItem(STORAGE_PREFIX + c)); } catch (e) { /* ignorieren */ }
    return v || memory[c] || null;
  }

  function saveCreds() {
    memory[code] = creds;
    try { localStorage.setItem(STORAGE_PREFIX + code, JSON.stringify(creds)); } catch (e) { /* ignorieren */ }
  }

  function clearCreds() {
    creds = null;
    delete memory[code];
    try { localStorage.removeItem(STORAGE_PREFIX + code); } catch (e) { /* ignorieren */ }
  }

  // -------------------------------------------------------------------------
  // Zustand
  // -------------------------------------------------------------------------

  var code = normalizeCode(new URLSearchParams(location.search).get('c'));
  var creds = null;        // { token, nickname, playerId, pending }
  var state = null;        // letzte Antwort von get_state
  var pending = null;      // Antwort, die gerade gesendet wird
  var draft = null;        // ungesendete Mehrfachauswahl { qid, ids }
  var notice = null;       // Hinweis unter der Frage
  var lastSeq = 0;
  var recoverToken = null;

  var running = false;
  var syncing = false;
  var syncAgain = false;
  var failCount = 0;
  var timer = null;
  var channel = null;
  var rtConnected = false;
  var lastRenderKey = null;

  function setOffline(on) {
    banner.hidden = !on;
  }

  // -------------------------------------------------------------------------
  // Einstieg: Code, Name, Recovery
  // -------------------------------------------------------------------------

  function form(title, text, label, inputProps, buttonLabel, error, onSubmit, extra) {
    var input = h('input', Object.assign({
      class: 'live-input', id: 'live-field', type: 'text',
      autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false'
    }, inputProps));
    var button = h('button', { class: 'live-btn', type: 'submit' }, buttonLabel);
    var err = h('p', { class: 'live-error', role: 'alert' }, error || '');
    var el = h('form', {
      class: 'live-form',
      onsubmit: function (ev) {
        ev.preventDefault();
        if (button.disabled) return;
        button.disabled = true;
        err.textContent = '';
        Promise.resolve(onSubmit(input.value)).then(function (message) {
          if (message) {
            err.textContent = message;
            button.disabled = false;
          }
        });
      }
    },
      h('h1', { class: 'live-title' }, title),
      h('p', { class: 'live-text' }, text),
      h('label', { class: 'live-label', for: 'live-field' }, label),
      input, err, button, extra
    );
    show(el);
    input.focus();
  }

  function showCodeForm(error) {
    form(T.codeTitle, T.codeText, T.codeLabel,
      { maxlength: '8', autocapitalize: 'characters', class: 'live-input live-input-code' },
      T.next, error,
      function (value) {
        var c = normalizeCode(value);
        if (!c) return T.errNotFound;
        location.search = '?c=' + encodeURIComponent(c);
      });
  }

  function joinErrorText(error) {
    return {
      SESSION_ENDED: T.errEnded,
      JOIN_LOCKED: T.errLocked,
      SESSION_FULL: T.errFull,
      INVALID_NICKNAME: T.errNick
    }[error] || T.errGeneric;
  }

  function showJoinForm(error) {
    form(T.joinTitle, T.joinText, T.nickLabel,
      { maxlength: '24', autocomplete: 'nickname', value: (creds && creds.nickname) || '' },
      T.join, error, join,
      h('button', { class: 'live-link', type: 'button', onclick: function () { showRecoverForm(); } }, T.wasHere));
  }

  // Das Token wird vor dem Request gespeichert. Geht die Antwort verloren,
  // liefert derselbe Request beim nächsten Versuch dieselbe Person.
  function join(nickname) {
    nickname = nickname.replace(/\s+/g, ' ').trim();
    if (!nickname || nickname.length > 24) return T.errNick;

    if (!creds || !creds.pending) creds = { token: newToken(), pending: true };
    creds.nickname = nickname;
    saveCreds();

    return TL.rpc('join_game', { p_join_code: code, p_nickname: nickname, p_token: creds.token })
      .then(function (res) {
        if (res.ok) {
          creds = { token: creds.token, nickname: res.nickname, playerId: res.player_id, pending: false };
          saveCreds();
          start();
          return null;
        }
        if (res.error === 'SESSION_NOT_FOUND') {
          clearCreds();
          showCodeForm(T.errNotFound);
          return null;
        }
        if (res.error === 'INVALID_TOKEN') clearCreds();
        return joinErrorText(res.error);
      }, function () {
        return T.errNetwork;
      });
  }

  function showRecoverForm() {
    // dasselbe Token für alle Versuche, damit ein wiederholter Request idempotent ist
    if (!recoverToken) recoverToken = newToken();
    form(T.recoverTitle, T.recoverText, T.recoverLabel,
      { maxlength: '8', autocapitalize: 'characters', class: 'live-input live-input-code' },
      T.recover, null,
      function (value) {
        return TL.rpc('recover_player', {
          p_join_code: code, p_code: normalizeCode(value), p_token: recoverToken
        }).then(function (res) {
          if (res.ok) {
            creds = { token: recoverToken, nickname: res.nickname, playerId: res.player_id, pending: false };
            recoverToken = null;
            saveCreds();
            start();
            return null;
          }
          if (res.error === 'SESSION_NOT_FOUND') return T.errNotFound;
          if (res.error === 'INVALID_CODE') return T.errCode;
          return T.errGeneric;
        }, function () {
          return T.errNetwork;
        });
      },
      h('button', { class: 'live-link', type: 'button', onclick: function () { showJoinForm(); } }, T.back));
  }

  // -------------------------------------------------------------------------
  // Synchronisation
  // -------------------------------------------------------------------------

  function start() {
    running = true;
    state = null;
    lastRenderKey = null;
    show(h('p', { class: 'live-text' }, T.loading));
    sync();
  }

  function stop() {
    running = false;
    clearTimeout(timer);
    setOffline(false);
    if (channel) {
      TL.client.removeChannel(channel);
      channel = null;
      rtConnected = false;
    }
  }

  function schedule(delay) {
    clearTimeout(timer);
    if (running) timer = setTimeout(sync, delay);
  }

  // Lädt den Stand neu. Läuft nie doppelt; ein Aufruf während eines laufenden
  // Requests führt zu genau einem weiteren Durchlauf danach.
  function sync() {
    if (!running) return;
    if (syncing) { syncAgain = true; return; }
    syncing = true;
    clearTimeout(timer);

    TL.rpc('get_state', { p_token: creds.token }).then(function (res) {
      failCount = 0;
      setOffline(false);
      if (res.ok) {
        state = res;
        subscribe(res.session.id);
        render();
        // Realtime verbunden: seltenes Polling als Lebenszeichen und Sicherheitsnetz.
        schedule((rtConnected ? 9000 : 4000) + Math.random() * 2000);
      } else {
        handleStateError(res.error);
      }
    }, function () {
      failCount++;
      if (failCount >= 2) setOffline(true);
      schedule(Math.min(5000, 500 * Math.pow(2, failCount)));
    }).then(function () {
      syncing = false;
      if (syncAgain) { syncAgain = false; sync(); }
    });
  }

  function handleStateError(error) {
    if (error === 'REMOVED') {
      stop();
      show(h('h1', { class: 'live-title' }, T.removedTitle), h('p', { class: 'live-text' }, T.removedText));
      return;
    }
    if (error === 'UNKNOWN_PLAYER') {
      stop();
      if (creds.pending && creds.nickname) {
        // Der Beitritt wurde gespeichert, aber nie bestätigt: mit demselben Token wiederholen.
        Promise.resolve(join(creds.nickname)).then(function (message) {
          if (message) showJoinForm(message);
        });
        return;
      }
      clearCreds();
      showJoinForm(T.errUnknown);
      return;
    }
    schedule(4000);
  }

  function subscribe(sessionId) {
    if (channel) return;
    channel = TL.client.channel('game:' + sessionId);
    channel
      .on('broadcast', { event: 'state' }, function () {
        // kleiner Zufallsversatz, damit nicht alle Geräte im selben Moment laden
        setTimeout(sync, Math.random() * 400);
      })
      .subscribe(function (status) {
        var was = rtConnected;
        rtConnected = status === 'SUBSCRIBED';
        // nach jedem (Wieder-)Verbinden könnte ein Signal verpasst worden sein
        if (rtConnected && !was) sync();
        // Realtime weg: nicht bis zum nächsten langsamen Polling warten
        else if (was && !rtConnected) schedule(3000 + Math.random() * 2000);
      });
  }

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') sync();
  });
  window.addEventListener('online', sync);
  window.addEventListener('pageshow', function (ev) {
    if (ev.persisted) sync();
  });

  // -------------------------------------------------------------------------
  // Antworten
  // -------------------------------------------------------------------------

  function savedIds() {
    return state.my_answer ? state.my_answer.option_ids : [];
  }

  function selectedIds() {
    var qid = state.question.id;
    if (pending && pending.qid === qid) return pending.ids;
    if (draft && draft.qid === qid) return draft.ids;
    return savedIds();
  }

  function tapOption(id) {
    var q = state.question;
    if (state.session.state !== 'QUESTION_OPEN') return;

    if (q.max_selections === 1) {
      if (!pending && sameIds(savedIds(), [id])) return;
      submit([id]);
      return;
    }

    var ids = selectedIds().slice();
    var at = ids.indexOf(id);
    if (at >= 0) ids.splice(at, 1);
    else if (ids.length < q.max_selections) ids.push(id);
    else return;
    draft = { qid: q.id, ids: ids };
    notice = null;
    render();
  }

  function submit(ids) {
    var seq = Math.max(Date.now(), lastSeq + 1, (state.my_answer ? state.my_answer.client_seq : 0) + 1);
    lastSeq = seq;
    pending = { qid: state.question.id, ids: ids, seq: seq, tries: 0 };
    draft = null;
    notice = null;
    render();
    send(pending);
  }

  // Wiederholt bei Netzfehlern mit derselben Nummer; der Server speichert pro
  // Person und Frage genau eine Antwort und übernimmt nur die höchste Nummer.
  function send(p) {
    TL.rpc('submit_answer', {
      p_token: creds.token, p_question_id: p.qid, p_option_ids: p.ids, p_client_seq: p.seq
    }).then(function (res) {
      if (pending !== p) return; // inzwischen wurde eine neuere Auswahl gesendet
      pending = null;
      setOffline(false);
      if (res.ok) {
        if (state && state.question && state.question.id === p.qid) {
          state.my_answer = { option_ids: res.option_ids, client_seq: res.client_seq };
        }
      } else if (res.error === 'QUESTION_NOT_OPEN') {
        notice = T.tooLate;
        sync();
      } else if (res.error === 'REMOVED' || res.error === 'UNKNOWN_PLAYER') {
        sync();
      } else {
        notice = T.saveFailed;
      }
      render();
    }, function () {
      if (pending !== p) return;
      p.tries++;
      if (p.tries >= 2) setOffline(true);
      setTimeout(function () {
        if (pending === p && running) send(p);
      }, Math.min(4000, 400 * Math.pow(2, p.tries)));
    });
  }

  // -------------------------------------------------------------------------
  // Darstellung
  // -------------------------------------------------------------------------

  function render() {
    if (!running || !state) return;
    var s = state.session.state;

    // Nur neu aufbauen, wenn sich etwas Sichtbares geändert hat – sonst könnte
    // ein Neuaufbau mitten im Tippen einen Klick verschlucken.
    var key = JSON.stringify([
      state.session, state.question, state.my_answer, state.results, state.my_question_score, state.answered_count,
      state.leaderboard, state.me,
      s === 'LOBBY' ? state.player_count : null, pending, draft, notice
    ]);
    if (key === lastRenderKey) return;
    lastRenderKey = key;

    if (s === 'LOBBY') show(viewLobby());
    // Slides laufen nur auf dem Presenter; hier steht ein neutraler Wartezustand.
    else if (s === 'SLIDE') show(h('h1', { class: 'live-title' }, T.slideTitle), h('p', { class: 'live-text' }, T.slideText));
    else if (state.question) show(viewQuestion());
    else if (state.leaderboard) show(viewLeaderboard());
    else show(h('p', { class: 'live-text' }, T.loading));
  }

  function viewLobby() {
    return [
      h('h1', { class: 'live-title' }, T.lobbyTitle),
      h('p', { class: 'live-text' }, T.lobbyText(state.player.nickname)),
      h('p', { class: 'live-status' }, T.lobbyCount(state.player_count))
    ];
  }

  function viewQuestion() {
    var q = state.question;
    var s = state.session.state;
    var open = s === 'QUESTION_OPEN';
    var isPoll = q.kind === 'poll';
    var multi = q.max_selections > 1;
    var selected = selectedIds();
    var saved = savedIds();

    // Ergebnisse kommen fertig aggregiert vom Server. Prozent = Anteil der
    // Personen, die überhaupt geantwortet haben; bei Mehrfachauswahl kann die
    // Summe deshalb über 100 % liegen.
    var results = {};
    if (state.results) state.results.forEach(function (r) { results[r.option_id] = r; });
    var answered = state.answered_count || 0;

    var options = q.options.map(function (o, index) {
      var isSelected = selected.indexOf(o.id) >= 0;
      var res = state.results ? (results[o.id] || { count: 0 }) : null;
      // Farbstufen (Quizfrage) und Mehrheit (Umfrage) gibt es erst in der Auflösung.
      var tier = res && res.tier;
      var bar = null;
      var count = null;
      if (res) {
        var percent = answered ? Math.round(100 * res.count / answered) : 0;
        bar = h('span', { class: 'live-option-bar', 'aria-hidden': 'true' });
        bar.style.width = Math.min(100, percent) + '%';
        count = h('span', { class: 'live-option-count' }, res.count + ' · ' + percent + ' %');
      }
      return h('li', null,
        h('button', {
          class: 'live-option' + (res ? ' is-result' : '') + (tier ? ' is-' + tier : '') + (res && res.top ? ' is-top' : ''),
          type: 'button',
          'aria-pressed': isSelected ? 'true' : 'false',
          disabled: !open,
          onclick: function () { tapOption(o.id); }
        },
          bar,
          // gleicher Buchstabe wie auf dem Presenter, damit Bilder und Clips dort eindeutig zuzuordnen sind
          h('span', { class: 'live-option-letter', 'aria-hidden': 'true' }, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.charAt(index)),
          tier ? h('span', { class: 'live-option-mark', title: T.tier[tier] }, TL.TIER_MARKS[tier]) : null,
          h('span', { class: 'live-option-label' }, o.label,
            tier ? h('span', { class: 'visually-hidden' }, ' – ' + T.tier[tier]) : null,
            res && res.top ? h('span', { class: 'visually-hidden' }, ' – ' + T.top) : null),
          res && isSelected ? h('span', { class: 'live-option-mine' }, T.mine) : null,
          count));
    });

    var status;
    if (notice) status = notice;
    else if (open && pending) status = T.saving;
    else if (open && multi && draft && !sameIds(draft.ids, saved)) status = T.unsent;
    else if (open && saved.length) status = T.saved;
    else if (open) status = '';
    else if (s === 'RESULTS') status = saved.length ? T.results : T.results + '. ' + T.noAnswer;
    else status = saved.length ? T.closed : T.closed + ' ' + T.noAnswer;

    var sendButton = null;
    if (open && multi) {
      var changed = !!draft && draft.ids.length > 0 && !sameIds(draft.ids, saved);
      sendButton = h('button', {
        class: 'live-btn',
        type: 'button',
        disabled: !changed || !!pending,
        onclick: function () { if (draft && draft.ids.length) submit(draft.ids.slice()); }
      }, saved.length ? T.sendChange : T.send);
    }

    // eigene Punkte für diese Frage, erst in der Auflösung und nie bei Umfragen
    var gain = null;
    if (state.results && typeof state.my_question_score === 'number') {
      var score = state.my_question_score;
      gain = h('p', { class: 'live-gain' + (score > 0 ? ' is-plus' : score < 0 ? ' is-minus' : '') },
        (score > 0 ? '+' : '') + T.points(score));
    }

    return [
      h('p', { class: 'live-tag' }, isPoll ? T.poll : T.question(q.number, q.total)),
      h('h1', { class: 'live-question' }, q.text),
      gain,
      // Hinweis nur bei Mehrfachauswahl, direkt über den Antworten
      open && multi ? h('p', { class: 'live-badge' }, T.pickMany(q.max_selections)) : null,
      h('ul', { class: 'live-options' }, options),
      sendButton,
      h('p', { class: 'live-status', role: 'status' }, status)
    ];
  }

  function viewLeaderboard() {
    var s = state.session.state;
    var me = state.me;
    // Die Antwortzeit entscheidet nur bei Punktegleichstand und wird erst im Finale gezeigt.
    var showTime = s !== 'LEADERBOARD';
    var rows = state.leaderboard.map(function (r) {
      return h('li', { class: r.me ? 'live-board-row is-me' : 'live-board-row' },
        h('span', { class: 'live-board-rank' }, r.rank + '.'),
        h('span', { class: 'live-board-name' }, r.name),
        showTime && r.tied ? h('span', { class: 'live-board-time' }, formatTime(r.time_ms)) : null,
        h('span', { class: 'live-board-score' }, r.score));
    });
    return [
      h('p', { class: 'live-tag' }, s === 'LEADERBOARD' ? T.standings : T.final),
      me ? h('h1', { class: 'live-title' }, T.place(me.rank)) : null,
      me ? h('p', { class: 'live-text' }, me.name + ' · ' + T.points(me.score) +
        (showTime && me.tied ? ' · ' + formatTime(me.time_ms) : '')) : null,
      h('ol', { class: 'live-board' }, rows),
      s === 'ENDED' ? h('p', { class: 'live-status' }, T.ended) : null
    ];
  }

  // -------------------------------------------------------------------------
  // Start
  // -------------------------------------------------------------------------

  if (!code) {
    showCodeForm();
  } else {
    creds = loadCreds(code);
    if (creds && creds.token) start();
    else showJoinForm();
  }
})();
