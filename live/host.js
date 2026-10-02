// Host-Ansicht für töricht live: Login, Übersicht und Steuerung einer Session.
// Der Spielstand liegt vollständig in der Datenbank; diese Seite kann jederzeit
// neu geladen oder auf einem anderen Gerät geöffnet werden.
(function () {
  'use strict';

  var TL = window.TL;
  TL.init({ hostAuth: true });

  var h = TL.h;
  var client = TL.client;
  var app = document.getElementById('app');
  var sessionId = new URLSearchParams(location.search).get('s');

  var STATE_LABELS = {
    LOBBY: 'lobby',
    SLIDE: 'slide sichtbar',
    QUESTION_OPEN: 'frage offen',
    QUESTION_CLOSED: 'frage geschlossen',
    RESULTS: 'ergebnisse sichtbar',
    LEADERBOARD: 'leaderboard sichtbar',
    FINAL_RESULTS: 'finale sichtbar',
    ENDED: 'beendet'
  };

  var ERRORS = {
    NOT_HOST: 'dieser account ist kein host.',
    SESSION_NOT_FOUND: 'diese session gibt es nicht.',
    QUIZ_EMPTY: 'dieses quiz hat noch keine fragen.',
    QUIZ_NOT_FOUND: 'dieses quiz gibt es nicht.',
    NO_MORE_QUESTIONS: 'es gibt keine weitere frage.',
    INVALID_TRANSITION: 'dieser schritt ist im aktuellen zustand nicht möglich.',
    PLAYER_NOT_FOUND: 'diese person gibt es nicht.',
    SESSION_ACTIVE: 'ein laufendes spiel kann nicht gelöscht werden. bitte zuerst beenden.'
  };

  function errorText(code) {
    return ERRORS[code] || 'etwas ist schiefgelaufen (' + code + ').';
  }

  function show() {
    TL.show.apply(null, [app].concat(Array.prototype.slice.call(arguments)));
  }

  // -------------------------------------------------------------------------
  // Login
  // -------------------------------------------------------------------------

  function showLogin(error) {
    var email = h('input', { class: 'live-input', id: 'host-email', type: 'email', autocomplete: 'username', required: true });
    var password = h('input', { class: 'live-input', id: 'host-password', type: 'password', autocomplete: 'current-password', required: true });
    var button = h('button', { class: 'live-btn', type: 'submit' }, 'einloggen');
    var err = h('p', { class: 'live-error', role: 'alert' }, error || '');

    show(h('form', {
      class: 'live-form host-login',
      onsubmit: function (ev) {
        ev.preventDefault();
        if (button.disabled) return;
        button.disabled = true;
        err.textContent = '';
        client.auth.signInWithPassword({ email: email.value.trim(), password: password.value })
          .then(function (res) {
            if (res.error) {
              err.textContent = 'login fehlgeschlagen. bitte e-mail und passwort prüfen.';
              button.disabled = false;
              return;
            }
            boot();
          }, function () {
            err.textContent = 'keine verbindung. bitte nochmal versuchen.';
            button.disabled = false;
          });
      }
    },
      h('h1', { class: 'live-title' }, 'host'),
      h('label', { class: 'live-label', for: 'host-email' }, 'e-mail'), email,
      h('label', { class: 'live-label host-gap', for: 'host-password' }, 'passwort'), password,
      err, button));
    email.focus();
  }

  function logout() {
    stop();
    client.auth.signOut().then(function () { location.href = './'; });
  }

  function boot() {
    show(h('p', { class: 'live-text' }, 'lädt …'));
    TL.checkHost().then(function (isHost) {
      if (!isHost) {
        client.auth.getSession().then(function (res) {
          if (res.data && res.data.session) {
            client.auth.signOut().then(function () { showLogin(ERRORS.NOT_HOST); });
          } else {
            showLogin();
          }
        });
        return;
      }
      if (sessionId) startControl();
      else showDashboard();
    }, function () {
      show(
        h('p', { class: 'live-error' }, 'keine verbindung zum server.'),
        h('button', { class: 'live-btn', type: 'button', onclick: boot }, 'nochmal versuchen'));
    });
  }

  // -------------------------------------------------------------------------
  // Übersicht: Quizze und Sessions
  // -------------------------------------------------------------------------

  function showDashboard(error) {
    Promise.all([
      client.from('quizzes').select('id, title, questions(kind)').order('created_at', { ascending: false }),
      client.from('game_sessions').select('id, join_code, state, created_at, quizzes(title)')
        .order('created_at', { ascending: false }).limit(20)
    ]).then(function (results) {
      if (results[0].error || results[1].error) throw new Error('load failed');
      var quizzes = results[0].data;
      var sessions = results[1].data;

      var quizRows = quizzes.map(function (z) {
        var items = z.questions || [];
        var slides = items.filter(function (q) { return q.kind === 'slide'; }).length;
        var polls = items.filter(function (q) { return q.kind === 'poll'; }).length;
        var count = items.length - slides - polls;
        var button = h('button', {
          class: 'host-btn host-btn-primary', type: 'button', disabled: count + polls === 0,
          onclick: function () {
            button.disabled = true;
            TL.rpc('host_create_session', { p_quiz_id: z.id }).then(function (res) {
              if (res.ok) location.search = '?s=' + res.session_id;
              else showDashboard(errorText(res.error));
            }, function () {
              showDashboard('keine verbindung. es wurde keine session gestartet.');
            });
          }
        }, 'session starten');
        return h('li', { class: 'host-row' },
          h('span', { class: 'host-row-main' }, z.title),
          h('span', { class: 'host-row-meta' }, (count === 1 ? '1 frage' : count + ' fragen') +
            (polls ? ', ' + (polls === 1 ? '1 umfrage' : polls + ' umfragen') : '') +
            (slides ? ', ' + (slides === 1 ? '1 slide' : slides + ' slides') : '')),
          h('a', { class: 'host-btn', href: 'editor/?q=' + z.id }, 'bearbeiten'),
          button);
      });

      var sessionRows = sessions.map(function (s) {
        return h('li', { class: 'host-row' },
          h('span', { class: 'host-row-main' }, (s.quizzes && s.quizzes.title) || 'quiz'),
          h('span', { class: 'host-row-meta' },
            s.join_code + ' · ' + STATE_LABELS[s.state] + ' · ' +
            new Date(s.created_at).toLocaleString('de', { dateStyle: 'short', timeStyle: 'short' })),
          // laufende Spiele müssen erst beendet werden
          s.state === 'ENDED' || s.state === 'LOBBY' ? h('button', {
            class: 'host-btn', type: 'button',
            onclick: function () {
              if (!window.confirm('session ' + s.join_code + ' mit allen personen und antworten endgültig löschen?')) return;
              TL.rpc('host_delete_session', { p_session_id: s.id }).then(function (res) {
                showDashboard(res.ok ? null : errorText(res.error));
              }, function () {
                showDashboard('keine verbindung. die session wurde nicht gelöscht.');
              });
            }
          }, 'löschen') : null,
          h('a', { class: 'host-btn', href: '?s=' + s.id }, s.state === 'ENDED' ? 'ansehen' : 'öffnen'));
      });

      show(
        h('header', { class: 'host-head' },
          h('h1', { class: 'host-title' }, 'töricht live – host'),
          h('button', { class: 'host-btn', type: 'button', onclick: logout }, 'ausloggen')),
        error ? h('p', { class: 'live-error', role: 'alert' }, error) : null,
        h('h2', { class: 'host-h2' }, 'sessions'),
        sessionRows.length ? h('ul', { class: 'host-list' }, sessionRows)
          : h('p', { class: 'host-empty' }, 'noch keine session.'),
        h('div', { class: 'host-h2-row' },
          h('h2', { class: 'host-h2' }, 'quizze'),
          h('a', { class: 'host-btn', href: 'editor/?new' }, '+ neues quiz')),
        quizRows.length ? h('ul', { class: 'host-list' }, quizRows)
          : h('p', { class: 'host-empty' }, 'noch kein quiz.'));
    }).catch(function () {
      show(
        h('p', { class: 'live-error' }, 'die übersicht konnte nicht geladen werden.'),
        h('button', { class: 'live-btn', type: 'button', onclick: function () { showDashboard(); } }, 'nochmal versuchen'));
    });
  }

  // -------------------------------------------------------------------------
  // Steuerung einer Session
  // -------------------------------------------------------------------------

  var state = null;       // letzte Antwort von host_get_state
  var running = false;
  var syncing = false;
  var syncAgain = false;
  var failCount = 0;
  var offline = false;
  var timer = null;
  var channel = null;
  var busy = false;       // eine Host-Aktion läuft
  var flash = null;       // Fehlermeldung der letzten Aktion
  var recovery = null;    // { name, code, expiresAt }
  var recoveryTimer = null;
  var lastRenderKey = null;

  function startControl() {
    running = true;
    show(h('p', { class: 'live-text' }, 'lädt …'));
    sync();
  }

  function stop() {
    running = false;
    clearTimeout(timer);
    clearInterval(recoveryTimer);
    if (channel) {
      client.removeChannel(channel);
      channel = null;
    }
  }

  function sync() {
    if (!running) return;
    if (syncing) { syncAgain = true; return; }
    syncing = true;
    clearTimeout(timer);

    TL.rpc('host_get_state', { p_session_id: sessionId }).then(function (res) {
      failCount = 0;
      offline = false;
      if (res.ok) {
        state = res;
        subscribe();
        render();
      } else if (res.error === 'NOT_HOST') {
        stop();
        showLogin('bitte neu einloggen.');
      } else {
        stop();
        show(
          h('p', { class: 'live-error' }, errorText(res.error)),
          h('a', { class: 'host-btn', href: './' }, '← übersicht'));
      }
    }, function () {
      failCount++;
      if (failCount >= 2) { offline = true; render(); }
    }).then(function () {
      syncing = false;
      if (!running) return;
      if (syncAgain) { syncAgain = false; sync(); }
      // Zähler (verbunden, geantwortet) kommen nur über Polling
      else timer = setTimeout(sync, 2000);
    });
  }

  function subscribe() {
    if (channel) return;
    channel = client.channel('game:' + sessionId);
    channel.on('broadcast', { event: 'state' }, function () { sync(); }).subscribe();
  }

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') sync();
  });
  window.addEventListener('online', sync);

  // Zustandswechsel. Die mitgeschickte Version sorgt dafür, dass ein Doppelklick
  // oder ein zweiter Host-Tab denselben Schritt nicht zweimal ausführt.
  function act(action, confirmText) {
    if (busy || !state) return;
    if (confirmText && !window.confirm(confirmText)) return;
    busy = true;
    flash = null;
    render();
    TL.rpc('host_action', {
      p_session_id: sessionId, p_expected_version: state.session.version, p_action: action
    }).then(function (res) {
      busy = false;
      if (!res.ok && res.error !== 'VERSION_MISMATCH') flash = errorText(res.error);
      lastRenderKey = null;
      sync();
    }, function () {
      busy = false;
      flash = 'keine verbindung – der schritt wurde vielleicht nicht ausgeführt. bitte den zustand prüfen.';
      render();
      sync();
    });
  }

  function call(name, args) {
    flash = null;
    return TL.rpc(name, args).then(function (res) {
      if (!res.ok) flash = errorText(res.error);
      lastRenderKey = null;
      sync();
      return res;
    }, function () {
      flash = 'keine verbindung. bitte nochmal versuchen.';
      render();
      return { ok: false };
    });
  }

  function createRecoveryCode(player) {
    call('host_create_recovery_code', { p_player_id: player.id }).then(function (res) {
      if (!res.ok) return;
      // Der Code gilt serverseitig 3 Minuten; hier etwas knapper anzeigen.
      recovery = { name: player.name, code: res.code, expiresAt: Date.now() + 175000 };
      clearInterval(recoveryTimer);
      recoveryTimer = setInterval(function () {
        if (!recovery || Date.now() >= recovery.expiresAt) {
          recovery = null;
          clearInterval(recoveryTimer);
        }
        lastRenderKey = null;
        render();
      }, 1000);
      render();
    });
  }

  // -------------------------------------------------------------------------
  // Darstellung
  // -------------------------------------------------------------------------

  function button(label, action, options) {
    options = options || {};
    return h('button', {
      class: 'host-btn' + (options.primary ? ' host-btn-primary' : '') + (options.danger ? ' host-btn-danger' : ''),
      type: 'button',
      disabled: busy || options.disabled,
      onclick: function () { act(action, options.confirm); }
    }, label);
  }

  function actionButtons() {
    var s = state.session.state;
    // Fragen und Slides teilen sich eine Reihenfolge; der Server sagt, was als Nächstes kommt.
    var nextKind = state.next ? state.next.kind : null;
    // Vor Migration 008 liefert der Server "next" noch nicht.
    var hasNext = state.next === undefined ? (state.question_number || 0) < state.question_total : !!nextKind;
    var next = function (primary) {
      var label = !hasNext ? 'kein weiterer eintrag'
        : nextKind === 'slide' ? 'weiter: slide zeigen'
        : nextKind === 'poll' ? 'weiter: umfrage starten' : 'weiter: frage starten';
      return button(label, 'OPEN_NEXT', { primary: primary && hasNext, disabled: !hasNext });
    };
    var final = function (primary) { return button('finale zeigen', 'SHOW_FINAL', { primary: primary }); };

    if (s === 'LOBBY') return [next(true)];
    if (s === 'SLIDE') return [
      next(true), final(!hasNext),
      button('leaderboard zeigen', 'SHOW_LEADERBOARD')
    ];
    if (s === 'QUESTION_OPEN') return [button('frage schließen', 'CLOSE', { primary: true })];
    if (s === 'QUESTION_CLOSED') return [
      button('ergebnisse zeigen', 'SHOW_RESULTS', { primary: true }),
      button('leaderboard zeigen', 'SHOW_LEADERBOARD'),
      next(false), final(false),
      button('frage wieder öffnen', 'REOPEN')
    ];
    if (s === 'RESULTS') return [
      button('leaderboard zeigen', 'SHOW_LEADERBOARD', { primary: true }),
      next(false), final(!hasNext)
    ];
    if (s === 'LEADERBOARD') return [
      next(true), final(!hasNext),
      button('leaderboard verstecken', 'SHOW_RESULTS')
    ];
    return [];
  }

  // In der Steuerung reicht ein Hinweis; abgespielt wird nur auf dem Presenter.
  function mediaNote(media) {
    if (!media) return null;
    var parts = [];
    if (media.video) parts.push('video' + (media.video.loop ? ' (loop)' : ''));
    if (media.audio && media.audio.length) {
      parts.push(media.audio.length === 1 ? '1 audio' : media.audio.length + ' audio-clips');
    }
    return parts.length ? h('p', { class: 'host-meta' }, 'auf dem presenter: ' + parts.join(', ')) : null;
  }

  function viewQuestion() {
    if (state.slide) {
      return [
        h('p', { class: 'host-meta' }, 'slide · nur auf dem presenter sichtbar'),
        state.slide.heading ? h('p', { class: 'host-question' }, state.slide.heading) : null,
        state.slide.text ? h('p', { class: 'host-slide-text' }, state.slide.text) : null,
        TL.imageRow(state.slide.images, 'host-images'),
        mediaNote(state.slide.media)
      ];
    }
    var q = state.question;
    if (!q) return h('p', { class: 'host-empty' }, 'noch nichts gestartet.');
    var isPoll = q.kind === 'poll';
    var tiers = TL.tiers(q.options.map(function (o) { return o.points; }));
    var answered = state.answered_count || 0;
    var selection = q.max_selections > 1 ? 'bis zu ' + q.max_selections + ' antworten' : 'eine antwort';
    return [
      h('p', { class: 'host-meta' },
        (isPoll ? 'umfrage · zählt nicht zur wertung' : 'frage ' + state.question_number + ' / ' + state.question_total) +
        ' · ' + selection),
      h('p', { class: 'host-question' }, q.text),
      TL.imageRow(q.images, 'host-images'),
      mediaNote(q.media),
      h('table', { class: 'host-table' },
        h('thead', null, h('tr', null,
          h('th', null, 'antwort'),
          isPoll ? null : h('th', { class: 'num' }, 'punkte'),
          h('th', { class: 'num' }, 'gewählt'))),
        h('tbody', null, q.options.map(function (o, i) {
          return h('tr', null,
            h('td', null,
              isPoll ? null : h('span', { class: 'ed-tier is-' + tiers[i], 'aria-hidden': 'true' }, TL.TIER_MARKS[tiers[i]]),
              o.label),
            isPoll ? null : h('td', { class: 'num' }, o.points),
            h('td', { class: 'num' }, o.count + (answered ? ' · ' + Math.round(100 * o.count / answered) + ' %' : '')));
        })))
    ];
  }

  function viewPlayers() {
    var rows = state.players.map(function (p) {
      return h('tr', { class: p.removed ? 'is-removed' : '' },
        h('td', { class: 'num' }, p.removed ? '–' : p.rank + '.'),
        h('td', null,
          h('span', { class: 'host-dot' + (p.connected ? ' is-on' : ''), title: p.connected ? 'verbunden' : 'nicht verbunden' }),
          p.name),
        h('td', { class: 'num' }, p.score),
        h('td', { class: 'num' }, TL.formatTime(p.time_ms)),
        h('td', { class: 'host-actions' },
          h('button', {
            class: 'host-btn host-btn-small', type: 'button',
            onclick: function () { createRecoveryCode(p); }
          }, 'recovery-code'),
          h('button', {
            class: 'host-btn host-btn-small', type: 'button',
            onclick: function () {
              if (!p.removed && !window.confirm(p.name + ' aus dem spiel entfernen?')) return;
              call('host_set_player_removed', { p_player_id: p.id, p_removed: !p.removed });
            }
          }, p.removed ? 'wieder aufnehmen' : 'entfernen')));
    });

    return h('table', { class: 'host-table' },
      h('thead', null, h('tr', null,
        h('th', { class: 'num' }, 'platz'), h('th', null, 'name'),
        h('th', { class: 'num' }, 'punkte'), h('th', { class: 'num' }, 'zeit'), h('th', null, ''))),
      h('tbody', null, rows));
  }

  function tieNotice() {
    var s = state.session.state;
    if (s === 'LOBBY' || s === 'ENDED') return null;
    var first = state.players.filter(function (p) { return !p.removed && p.rank === 1; });
    if (first.length > 1) {
      return h('p', { class: 'host-warn' },
        'exakter gleichstand auf platz 1 (' + first.length + ' personen mit gleichen punkten und gleicher zeit).');
    }
    if (first.length === 1 && first[0].tied) {
      return h('p', { class: 'host-info' },
        'punktegleichstand an der spitze – die antwortzeit entscheidet für ' + first[0].name + '.');
    }
    return null;
  }

  // Während ein Klick läuft, nicht neu aufbauen – sonst ginge er ins Leere.
  var pointerDown = false;
  document.addEventListener('pointerdown', function () { pointerDown = true; });
  ['pointerup', 'pointercancel'].forEach(function (name) {
    document.addEventListener(name, function () {
      pointerDown = false;
      setTimeout(render, 0);
    });
  });

  function render() {
    if (!running || !state || pointerDown) return;

    var key = JSON.stringify([state, busy, flash, offline,
      recovery && [recovery.code, Math.ceil((recovery.expiresAt - Date.now()) / 1000)]]);
    if (key === lastRenderKey) return;
    lastRenderKey = key;

    var s = state.session;
    var ended = s.state === 'ENDED';
    var playUrl = location.origin + '/play/?c=' + s.join_code;

    var recoveryBox = null;
    if (recovery) {
      var left = Math.max(0, Math.ceil((recovery.expiresAt - Date.now()) / 1000));
      recoveryBox = h('div', { class: 'host-recovery', role: 'status' },
        h('p', null, 'recovery-code für ', h('strong', null, recovery.name), ':'),
        h('p', { class: 'host-recovery-code' }, recovery.code),
        h('p', { class: 'host-meta' },
          'einmal gültig, noch ' + Math.floor(left / 60) + ':' + ('0' + (left % 60)).slice(-2) +
          ' min. die person tippt auf „ich war schon dabei".'),
        h('button', {
          class: 'host-btn host-btn-small', type: 'button',
          onclick: function () { recovery = null; clearInterval(recoveryTimer); render(); }
        }, 'schließen'));
    }

    show(
      h('header', { class: 'host-head' },
        h('a', { class: 'host-btn', href: './' }, '← übersicht'),
        h('h1', { class: 'host-title' }, s.quiz_title),
        h('span', { class: 'host-state' }, STATE_LABELS[s.state]),
        h('button', { class: 'host-btn', type: 'button', onclick: logout }, 'ausloggen')),

      offline ? h('p', { class: 'host-warn', role: 'alert' }, 'keine verbindung zum server – die anzeige ist evtl. veraltet.') : null,
      flash ? h('p', { class: 'host-warn', role: 'alert' }, flash) : null,

      h('div', { class: 'host-grid' },
        h('section', { class: 'host-panel' },
          h('div', { class: 'host-join' },
            h('div', null,
              h('p', { class: 'host-meta' }, 'join-code'),
              h('p', { class: 'host-code' }, s.join_code),
              h('p', { class: 'host-meta host-url' }, playUrl)),
            h('div', { class: 'host-join-actions' },
              h('a', { class: 'host-btn', href: '../presenter/?s=' + s.id, target: '_blank', rel: 'noopener' }, 'presenter öffnen'),
              ended ? null : h('button', {
                class: 'host-btn', type: 'button',
                onclick: function () {
                  call('host_set_join_locked', { p_session_id: s.id, p_locked: !s.join_locked });
                }
              }, s.join_locked ? 'beitritt wieder erlauben' : 'beitritt sperren'))),

          h('div', { class: 'host-stats' },
            h('p', null, h('strong', null, state.connected_count), ' von ' + state.player_count + ' verbunden'),
            state.question && s.state !== 'LOBBY'
              ? h('p', null, h('strong', null, state.answered_count), ' von ' + state.player_count + ' haben geantwortet')
              : null,
            s.join_locked ? h('p', { class: 'host-info' }, 'beitritt ist gesperrt.') : null),

          h('div', { class: 'host-buttons' }, actionButtons()),
          tieNotice(),

          h('h2', { class: 'host-h2' }, 'aktuell'),
          viewQuestion(),

          ended ? null : h('div', { class: 'host-end' },
            s.state === 'FINAL_RESULTS'
              ? button('spiel beenden', 'END', { primary: true })
              : button('spiel vorzeitig beenden', 'END', {
                danger: true,
                confirm: 'das spiel wirklich beenden? danach können keine fragen mehr gestartet werden.'
              }))),

        h('section', { class: 'host-panel' },
          h('h2', { class: 'host-h2' }, 'spieler:innen'),
          recoveryBox,
          state.players.length ? viewPlayers() : h('p', { class: 'host-empty' }, 'noch niemand dabei.')))
    );
  }

  boot();
})();
