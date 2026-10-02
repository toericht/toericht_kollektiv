// Presenter-Ansicht (Beamer) für töricht live.
// Nutzt den Host-Login desselben Browsers, lädt aber über presenter_get_state
// nur, was im aktuellen Zustand gezeigt wird: Punktwerte und Stimmen erst in der
// Auflösung, die Rangliste erst im Leaderboard.
// Bilder, Video und Ton laufen ausschließlich hier, nie auf den Handys.
(function () {
  'use strict';

  var TL = window.TL;
  TL.init({ hostAuth: true });

  var h = TL.h;
  var client = TL.client;
  var app = document.getElementById('app');
  var params = new URLSearchParams(location.search);
  var sessionId = params.get('s');
  var isEn = params.get('lang') === 'en';
  var lang = isEn ? 'en' : 'de';
  document.documentElement.lang = lang;

  var T = isEn ? {
    start: 'start presenter',
    startText: 'one click enables sound and video for this session.',
    join: 'join in',
    code: 'code',
    people: function (n) { return n === 1 ? '1 person is in' : n + ' people are in'; },
    question: function (a, b) { return 'question ' + a + ' / ' + b; },
    poll: 'poll',
    answered: function (a, b) { return a + ' of ' + b + ' have answered'; },
    votes: function (n) { return n === 1 ? '1 vote' : n + ' votes'; },
    closed: 'answers are closed',
    play: 'play',
    stop: 'stop',
    soundOn: 'turn sound on',
    standings: 'standings',
    final: 'final ranking',
    winner: 'the winner is',
    winners: 'the winners are',
    points: function (p) { return p === 1 || p === -1 ? p + ' point' : p + ' points'; },
    ended: 'thanks for playing!',
    needLogin: 'please log in on the host page first.',
    toHost: 'go to host page',
    noSession: 'no session selected. open the presenter from the host page.',
    offline: 'reconnecting …',
    fullscreen: 'fullscreen'
  } : {
    start: 'presenter starten',
    startText: 'ein klick schaltet ton und video für diese session frei.',
    join: 'mitspielen',
    code: 'code',
    people: function (n) { return n === 1 ? '1 person ist dabei' : n + ' personen sind dabei'; },
    question: function (a, b) { return 'frage ' + a + ' / ' + b; },
    poll: 'umfrage',
    answered: function (a, b) { return a + ' von ' + b + ' haben geantwortet'; },
    votes: function (n) { return n === 1 ? '1 stimme' : n + ' stimmen'; },
    closed: 'antworten sind geschlossen',
    play: 'abspielen',
    stop: 'stopp',
    soundOn: 'ton einschalten',
    standings: 'zwischenstand',
    final: 'endstand',
    winner: 'gewonnen hat',
    winners: 'gewonnen haben',
    points: function (p) { return p === 1 || p === -1 ? p + ' punkt' : p + ' punkte'; },
    ended: 'danke fürs mitspielen!',
    needLogin: 'bitte zuerst in der host-ansicht einloggen.',
    toHost: 'zur host-ansicht',
    noSession: 'keine session ausgewählt. öffne den presenter aus der host-ansicht.',
    offline: 'verbindung wird wiederhergestellt …',
    fullscreen: 'vollbild'
  };

  var LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  var state = null;
  var running = false;
  var syncing = false;
  var syncAgain = false;
  var failCount = 0;
  var timer = null;
  var channel = null;
  var lastRenderKey = null;
  var noteEl = null;       // Zeile "x von y haben geantwortet", wird ohne Neuaufbau aktualisiert
  var banner = document.getElementById('conn-banner');
  banner.textContent = T.offline;

  var fsButton = document.getElementById('fullscreen');
  fsButton.textContent = T.fullscreen;
  fsButton.addEventListener('click', function () {
    if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen();
  });

  // -------------------------------------------------------------------------
  // Medien: Jeder Neuaufbau der Ansicht stoppt zuerst alles, was läuft. Ein
  // Neuaufbau passiert bei jedem Zustandswechsel und nur dann – nicht, wenn
  // sich bloß die Zahl der Antworten ändert.
  // -------------------------------------------------------------------------

  var activeMedia = [];    // alle <video>/<audio> der aktuellen Ansicht
  var clips = [];          // [{ audio, button }] der aktuellen Frage
  var questionVideo = null;

  function track(el) {
    activeMedia.push(el);
    return el;
  }

  function stopAllMedia() {
    activeMedia.forEach(function (el) {
      try {
        el.pause();
        el.removeAttribute('src');
        el.load();
      } catch (e) { /* Element ist schon weg */ }
    });
    activeMedia = [];
    clips = [];
    questionVideo = null;
  }

  function show() {
    TL.show.apply(null, [app].concat(Array.prototype.slice.call(arguments)));
  }

  // Muss VOR dem Aufbau einer neuen Ansicht laufen: stoppt alles, was noch
  // spielt, bevor die neue Ansicht ihre eigenen Medien anlegt.
  function reset() {
    stopAllMedia();
    noteEl = null;
  }

  function message(text, link) {
    reset();
    show(h('div', { class: 'pres-center' },
      h('p', { class: 'pres-note' }, text),
      link ? h('a', { class: 'live-btn', href: '../host/' }, T.toHost) : null));
  }

  // Startet ein Medium. Blockiert der Browser den Ton, erscheint ein Knopf.
  function autoplay(el, host) {
    var result = el.play();
    if (!result || !result.catch) return;
    result.catch(function () {
      if (activeMedia.indexOf(el) < 0) return;
      var button = h('button', {
        class: 'pres-sound', type: 'button',
        onclick: function () { el.play(); button.remove(); }
      }, T.soundOn);
      host.appendChild(button);
    });
  }

  function makeVideo(video, isSlide) {
    var el = track(h('video', { src: TL.imageUrl(video.path), playsinline: true, preload: 'auto' }));
    el.loop = !!video.loop;
    // Auf Slides läuft das Video von selbst; bei Fragen startet es der Host.
    if (!isSlide) {
      el.controls = true;
      el.addEventListener('play', function () { stopClips(); });
      questionVideo = el;
    }
    return el;
  }

  // Bilder und Video teilen sich ein Raster; nichts wird verzerrt oder beschnitten.
  function mediaGrid(images, media, isSlide) {
    var cells = (images || []).map(function (path, i) {
      var img = h('img', { src: TL.imageUrl(path), alt: '' });
      // Beschriftung, damit Antworten auf dem Handy eindeutig zuzuordnen sind
      return media && media.image_labels
        ? h('figure', { class: 'pres-figure' }, img, h('figcaption', null, LETTERS.charAt(i)))
        : img;
    });
    var video = media && media.video ? makeVideo(media.video, isSlide) : null;
    if (video) cells.push(video);
    if (!cells.length) return null;
    var grid = h('div', { class: 'pres-images is-' + cells.length }, cells);
    if (video && isSlide) autoplay(video, grid);
    return grid;
  }

  // Audio-Clips einer Frage: A, B, C … Es läuft immer höchstens einer.
  function stopClips(except) {
    clips.forEach(function (c) {
      if (c === except) return;
      c.audio.pause();
      c.audio.currentTime = 0;
      setClipLabel(c, false);
    });
  }

  function setClipLabel(clip, playing) {
    clip.button.classList.toggle('is-playing', playing);
    clip.label.textContent = playing ? '■ ' + T.stop : '▶ ' + T.play;
  }

  function toggleClip(index) {
    var clip = clips[index];
    if (!clip) return;
    if (!clip.audio.paused) {
      clip.audio.pause();
      clip.audio.currentTime = 0;
      setClipLabel(clip, false);
      return;
    }
    stopClips(clip);
    if (questionVideo) questionVideo.pause();
    clip.audio.currentTime = 0;
    clip.audio.play();
    setClipLabel(clip, true);
  }

  function clipRow(media) {
    if (!media || !media.audio || !media.audio.length) return null;
    var buttons = media.audio.map(function (a, i) {
      var audio = track(new Audio(TL.imageUrl(a.path)));
      audio.loop = !!a.loop;
      audio.volume = typeof a.volume === 'number' ? a.volume : 1;
      audio.preload = 'auto';
      var label = h('span', { class: 'pres-clip-label' });
      var button = h('button', {
        class: 'pres-clip', type: 'button',
        onclick: function () { toggleClip(i); }
      }, h('span', { class: 'pres-clip-letter' }, LETTERS.charAt(i)), label);
      var clip = { audio: audio, button: button, label: label };
      audio.addEventListener('ended', function () { setClipLabel(clip, false); });
      setClipLabel(clip, false);
      clips.push(clip);
      return button;
    });
    return h('div', { class: 'pres-clips' }, buttons);
  }

  // Tastatur: A–F startet/stoppt den Clip, Leertaste das Video der Frage.
  document.addEventListener('keydown', function (ev) {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    var index = LETTERS.indexOf((ev.key || '').toUpperCase());
    if (ev.key && ev.key.length === 1 && index >= 0 && index < clips.length) {
      toggleClip(index);
    } else if (ev.key === ' ' && questionVideo) {
      ev.preventDefault();
      if (questionVideo.paused) questionVideo.play();
      else questionVideo.pause();
    }
  });

  // -------------------------------------------------------------------------
  // Synchronisation
  // -------------------------------------------------------------------------

  function sync() {
    if (!running) return;
    if (syncing) { syncAgain = true; return; }
    syncing = true;
    clearTimeout(timer);

    TL.rpc('presenter_get_state', { p_session_id: sessionId }).then(function (res) {
      failCount = 0;
      banner.hidden = true;
      if (res.ok) {
        state = res;
        subscribe();
        render();
      } else {
        running = false;
        message(res.error === 'NOT_HOST' ? T.needLogin : T.noSession, true);
      }
    }, function () {
      failCount++;
      if (failCount >= 2) banner.hidden = false;
    }).then(function () {
      syncing = false;
      if (!running) return;
      if (syncAgain) { syncAgain = false; sync(); }
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

  // -------------------------------------------------------------------------
  // Ansichten
  // -------------------------------------------------------------------------

  function playHost() {
    return location.host + '/play';
  }

  function qr(url) {
    var code = window.qrcode(0, 'M');
    code.addData(url);
    code.make();
    var box = h('div', { class: 'pres-qr' });
    // SVG stammt aus der QR-Bibliothek und enthält nur die eigene URL
    box.innerHTML = code.createSvgTag({ cellSize: 8, margin: 16, scalable: true });
    return box;
  }

  function joinHint() {
    return h('p', { class: 'pres-corner' }, T.join + ': ' + playHost() + ' · ' + state.session.join_code);
  }

  function viewLobby() {
    var s = state.session;
    return h('div', { class: 'pres-lobby' },
      h('div', { class: 'pres-lobby-text' },
        h('p', { class: 'pres-tag' }, T.join),
        h('p', { class: 'pres-url' }, playHost()),
        h('p', { class: 'pres-label' }, T.code),
        h('p', { class: 'pres-code' }, s.join_code),
        h('p', { class: 'pres-note' }, T.people(state.player_count))),
      qr(location.origin + '/play/?c=' + s.join_code));
  }

  function questionTag(q) {
    return q.kind === 'poll' ? T.poll : T.question(state.question_number, state.question_total);
  }

  function noteText() {
    return state.session.state === 'QUESTION_OPEN'
      ? T.answered(state.answered_count, state.player_count) : T.closed;
  }

  // Offene oder geschlossene Frage: Antworten neutral, ohne jeden Hinweis auf Punkte.
  function viewQuestion() {
    var q = state.question;
    var options = q.options.map(function (o, i) {
      return h('li', { class: 'pres-option' },
        h('span', { class: 'pres-option-letter' }, LETTERS.charAt(i)),
        h('span', { class: 'pres-option-label' }, o.label));
    });

    var grid = mediaGrid(q.images, q.media, false);
    var clipButtons = clipRow(q.media);
    noteEl = h('p', { class: 'pres-note' }, noteText());

    return h('div', { class: 'pres-question' + (grid ? ' has-images' : '') },
      h('p', { class: 'pres-tag' }, questionTag(q)),
      h('h1', { class: 'pres-question-text' }, q.text),
      grid,
      clipButtons,
      h('ul', { class: 'pres-options' + (q.options.length > 4 ? ' is-dense' : '') }, options),
      noteEl,
      state.session.state === 'QUESTION_OPEN' ? joinHint() : null);
  }

  function signedPoints(points) {
    return (points > 0 ? '+' : points < 0 ? '−' : '') + T.points(Math.abs(points));
  }

  // Auflösung als horizontale Balken. Die Zahlen kommen aggregiert vom Server
  // und erst in diesem Zustand: Stimmen pro Antwort, Personen mit Antwort und –
  // nur bei gewerteten Fragen – die Punkte jeder Antwort. Der Prozentwert ist
  // Stimmen / Personen mit Antwort; bei Mehrfachauswahl kann die Summe über
  // 100 % liegen.
  function viewResults() {
    var q = state.question;
    var isPoll = q.kind === 'poll';
    var answered = state.answered_count || 0;
    var tiers = isPoll ? [] : TL.tiers(q.options.map(function (o) { return o.points; }));
    var maxCount = 0;
    q.options.forEach(function (o) { if (o.count > maxCount) maxCount = o.count; });

    var rows = q.options.map(function (o, i) {
      var percent = answered ? Math.round(100 * o.count / answered) : 0;
      // Quizfrage: Farbstufe nach Punkten. Umfrage: meistgewählte Antwort(en) hervorgehoben.
      var kind = isPoll ? (o.count > 0 && o.count === maxCount ? 'is-top' : 'is-rest') : 'is-' + tiers[i];
      var fill = h('span', { class: 'pres-bar-fill' });
      fill.style.width = Math.min(100, percent) + '%';
      return h('li', { class: 'pres-bar ' + kind },
        h('div', { class: 'pres-bar-head' },
          h('span', { class: 'pres-bar-letter' }, LETTERS.charAt(i)),
          h('span', { class: 'pres-bar-label' }, o.label),
          isPoll ? null : h('span', { class: 'pres-bar-points' },
            h('span', { 'aria-hidden': 'true' }, TL.TIER_MARKS[tiers[i]] + ' '), signedPoints(o.points)),
          h('span', { class: 'pres-bar-value' },
            h('strong', null, percent + ' %'), ' · ' + T.votes(o.count))),
        h('div', { class: 'pres-bar-track' }, fill));
    });

    return h('div', { class: 'pres-results' },
      h('p', { class: 'pres-tag' }, questionTag(q)),
      h('h1', { class: 'pres-results-text' }, q.text),
      h('ul', { class: 'pres-bars' + (q.options.length > 4 ? ' is-dense' : '') }, rows),
      h('p', { class: 'pres-note' }, T.answered(answered, state.player_count)));
  }

  function viewSlide() {
    var slide = state.slide;
    var root = h('div', { class: 'pres-slide' },
      slide.heading ? h('h1', { class: 'pres-slide-heading' }, slide.heading) : null,
      slide.text ? h('p', { class: 'pres-slide-text' }, slide.text) : null,
      mediaGrid(slide.images, slide.media, true));

    // atmosphärischer Sound: startet mit der Slide, endet mit ihr
    var sound = slide.media && slide.media.audio && slide.media.audio[0];
    if (sound) {
      var audio = track(new Audio(TL.imageUrl(sound.path)));
      audio.loop = !!sound.loop;
      audio.volume = typeof sound.volume === 'number' ? sound.volume : 1;
      autoplay(audio, root);
    }
    return root;
  }

  // Bilder des nächsten Eintrags schon laden, damit der Wechsel ohne Verzögerung kommt.
  var preloaded = {};
  function preloadNext() {
    if (!state.next || !state.next.images) return;
    state.next.images.forEach(function (p) {
      if (preloaded[p]) return;
      preloaded[p] = new Image();
      preloaded[p].src = TL.imageUrl(p);
    });
  }

  function viewBoard() {
    var s = state.session.state;
    var isFinal = s !== 'LEADERBOARD';
    var top = state.leaderboard || [];
    var winners = top.filter(function (p) { return p.rank === 1; });

    var rows = top.map(function (p) {
      return h('li', { class: 'pres-board-row' + (isFinal && p.rank === 1 ? ' is-first' : '') },
        h('span', { class: 'pres-board-rank' }, p.rank + '.'),
        h('span', { class: 'pres-board-name' }, p.name),
        // die Antwortzeit entscheidet nur bei Punktegleichstand und wird erst im Finale gezeigt
        isFinal && p.tied ? h('span', { class: 'pres-board-time' }, TL.formatTime(p.time_ms, lang)) : null,
        h('span', { class: 'pres-board-score' }, p.score));
    });

    return h('div', { class: 'pres-board-wrap' },
      h('p', { class: 'pres-tag' }, isFinal ? T.final : T.standings),
      isFinal && winners.length ? h('div', { class: 'pres-winner' },
        h('p', { class: 'pres-label' }, winners.length > 1 ? T.winners : T.winner),
        h('p', { class: 'pres-winner-name' }, winners.map(function (p) { return p.name; }).join(' & ')),
        h('p', { class: 'pres-note' }, T.points(winners[0].score))) : null,
      h('ol', { class: 'pres-board' + (top.length > 5 ? ' is-two-col' : '') }, rows),
      s === 'ENDED' ? h('p', { class: 'pres-note' }, T.ended) : null);
  }

  function render() {
    if (!running || !state) return;
    var s = state.session.state;
    preloadNext();

    // Die Zahl der Antworten gehört bewusst nicht zum Schlüssel: Sie ändert sich
    // laufend, und ein Neuaufbau würde laufende Clips oder Videos abbrechen.
    var key = JSON.stringify([state.session, state.question, state.slide, state.leaderboard,
      s === 'LOBBY' ? state.player_count : null]);
    if (key === lastRenderKey) {
      if (noteEl) noteEl.textContent = noteText();
      return;
    }
    lastRenderKey = key;

    reset();
    document.body.setAttribute('data-state', s);
    if (s === 'LOBBY') show(viewLobby());
    else if (s === 'SLIDE' && state.slide) show(viewSlide());
    else if (s === 'RESULTS' && state.question) show(viewResults());
    else if (state.question) show(viewQuestion());
    else show(viewBoard());
  }

  // -------------------------------------------------------------------------
  // Start: Ein Klick schaltet Ton und Video für diese Sitzung frei
  // (Browser erlauben automatisches Abspielen mit Ton erst nach einer Aktion).
  // -------------------------------------------------------------------------

  function start() {
    running = true;
    lastRenderKey = null;
    show(h('div', { class: 'pres-center' }));
    sync();
  }

  if (!sessionId) {
    message(T.noSession, true);
  } else {
    TL.checkHost().then(function (isHost) {
      if (!isHost) { message(T.needLogin, true); return; }
      show(h('div', { class: 'pres-center' },
        h('button', { class: 'live-btn pres-start', type: 'button', onclick: start }, T.start),
        h('p', { class: 'pres-note' }, T.startText)));
    }, function () {
      banner.hidden = false;
      setTimeout(function () { location.reload(); }, 3000);
    });
  }
})();
