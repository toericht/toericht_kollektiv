// Quiz-Editor für töricht live. Bearbeitet ein Quiz im Speicher und sichert es
// immer als Ganzes über host_save_quiz – es gibt keinen halb gespeicherten Stand.
// Fragen und Slides bilden eine gemeinsame, frei sortierbare Liste.
(function () {
  'use strict';

  var TL = window.TL;
  TL.init({ hostAuth: true });

  var h = TL.h;
  var client = TL.client;
  var app = document.getElementById('app');
  var params = new URLSearchParams(location.search);

  // { id, title, items: [
  //   { id, kind: 'question', text, max_selections, images: [], options: [{ id, label, points }] },
  //   { id, kind: 'slide', heading, text, images: [] } ] }
  var quiz = null;
  var dirty = false;
  var saving = false;
  var uploading = 0;
  var lockedBy = null;   // Join-Code einer laufenden Session
  var message = null;    // { text, error }
  var statusEl = null;
  var saveButton = null;
  var uploaded = [];     // in dieser Sitzung hochgeladene Bilder (zum Aufräumen)

  var ERRORS = {
    NOT_HOST: 'bitte neu einloggen.',
    INVALID_TITLE: 'das quiz braucht einen titel (höchstens 200 zeichen).',
    INVALID_QUIZ: 'das quiz ist nicht lesbar.',
    INVALID_ITEM: 'unbekannte art von eintrag.',
    INVALID_QUESTION: 'der fragetext fehlt oder ist zu lang (höchstens 500 zeichen).',
    INVALID_OPTIONS: 'die frage braucht mindestens zwei antworten.',
    INVALID_MAX_SELECTIONS: 'die anzahl wählbarer antworten passt nicht zur anzahl der antworten.',
    INVALID_LABEL: 'eine antwort ist leer oder zu lang (höchstens 200 zeichen).',
    INVALID_POINTS: 'punkte müssen ganze zahlen sein (auch negativ).',
    INVALID_SLIDE: 'überschrift (höchstens 200 zeichen) oder text (höchstens 1000 zeichen) der slide sind zu lang.',
    EMPTY_SLIDE: 'die slide ist leer. sie braucht eine überschrift, einen text oder ein bild.',
    INVALID_LEADERBOARD: 'ein zwischenstand hat keine antworten.',
    INVALID_MEDIA: 'video oder audio dieses eintrags sind ungültig.',
    INVALID_IMAGES: 'die bilder dieses eintrags sind ungültig (höchstens sechs).',
    QUIZ_NOT_FOUND: 'dieses quiz gibt es nicht mehr.',
    QUIZ_LOCKED: 'für dieses quiz läuft gerade eine session. bearbeiten geht erst, wenn sie beendet oder gelöscht ist.',
    QUIZ_HAS_SESSIONS: 'zu diesem quiz gibt es noch sessions. lösche sie zuerst in der übersicht.',
    QUESTION_IN_USE: 'ein gelöschter eintrag wurde schon gespielt. lösche die alte session in der übersicht oder dupliziere das quiz.'
  };

  function errorText(res) {
    var text = ERRORS[res.error] || 'etwas ist schiefgelaufen (' + res.error + ').';
    return res.question ? 'eintrag ' + res.question + ': ' + text : text;
  }

  function newOption() { return { id: null, label: '', points: 0 }; }
  function newQuestion() {
    return {
      id: null, kind: 'question', text: '', max_selections: 1, images: [], media: emptyMedia(),
      options: [newOption(), newOption()]
    };
  }
  function newLeaderboard() { return { id: null, kind: 'leaderboard', images: [], media: emptyMedia() }; }
  function newSlide() { return { id: null, kind: 'slide', heading: '', text: '', images: [], media: emptyMedia() }; }

  // -------------------------------------------------------------------------
  // Laden und Speichern
  // -------------------------------------------------------------------------

  function byPosition(a, b) { return a.position - b.position; }

  function loadQuiz(id) {
    return Promise.all([
      client.from('quizzes')
        .select('id, title, questions(id, position, kind, heading, text, max_selections, image_paths, media, ' +
          'answer_options(id, position, label, points))')
        .eq('id', id).maybeSingle(),
      client.from('game_sessions').select('join_code').eq('quiz_id', id).neq('state', 'ENDED').limit(1)
    ]).then(function (results) {
      if (results[0].error || results[1].error) throw new Error('load failed');
      var row = results[0].data;
      if (!row) return null;
      lockedBy = results[1].data.length ? results[1].data[0].join_code : null;
      return {
        id: row.id,
        title: row.title,
        items: row.questions.sort(byPosition).map(function (q) {
          if (q.kind === 'leaderboard') return { id: q.id, kind: 'leaderboard', images: [], media: emptyMedia() };
          if (q.kind === 'slide') {
            return {
              id: q.id, kind: 'slide', heading: q.heading || '', text: q.text || '',
              images: q.image_paths || [], media: readMedia(q.media)
            };
          }
          return {
            id: q.id, kind: q.kind === 'poll' ? 'poll' : 'question', text: q.text, max_selections: q.max_selections,
            images: q.image_paths || [], media: readMedia(q.media),
            options: q.answer_options.sort(byPosition).map(function (o) {
              return { id: o.id, label: o.label, points: o.points };
            })
          };
        })
      };
    });
  }

  function payload(withIds) {
    return {
      id: withIds ? quiz.id : null,
      title: quiz.title,
      items: quiz.items.map(function (it) {
        if (it.kind === 'leaderboard') return { id: withIds ? it.id : null, kind: 'leaderboard' };
        if (it.kind === 'slide') {
          return {
            id: withIds ? it.id : null, kind: 'slide',
            heading: it.heading, text: it.text, images: it.images.slice(), media: writeMedia(it)
          };
        }
        return {
          id: withIds ? it.id : null, kind: it.kind,
          text: it.text,
          max_selections: Math.min(it.max_selections, Math.max(1, it.options.length)),
          images: it.images.slice(),
          media: writeMedia(it),
          options: it.options.map(function (o) {
            // Umfragen haben keine Punkte; der Server speichert dort ohnehin immer 0.
            return { id: withIds ? o.id : null, label: o.label, points: it.kind === 'poll' ? 0 : o.points };
          })
        };
      })
    };
  }

  function setDirty() {
    dirty = true;
    message = null;
    updateStatus();
  }

  function updateStatus() {
    if (!statusEl) return;
    statusEl.textContent = saving ? 'speichert …'
      : uploading ? 'bild wird hochgeladen …'
      : message ? message.text
      : dirty ? 'ungespeicherte änderungen'
      : quiz.id ? 'gespeichert' : 'neues quiz, noch nicht gespeichert';
    statusEl.className = 'ed-status' + (message && message.error ? ' is-error' : '');
    if (saveButton) saveButton.disabled = saving || uploading > 0 || !!lockedBy;
  }

  function save(data, isCopy) {
    if (saving || uploading) return;
    saving = true;
    message = null;
    updateStatus();
    TL.rpc('host_save_quiz', { p_quiz: data }, 15000).then(function (res) {
      saving = false;
      if (!res.ok) {
        message = { text: errorText(res), error: true };
        updateStatus();
        return;
      }
      return cleanupImages(isCopy ? [] : res.removed_images || [], isCopy).then(function () {
        dirty = false;
        if (isCopy || data.id === null) {
          location.href = '?q=' + res.quiz_id;
          return;
        }
        // neu laden, damit neue Einträge und Antworten ihre IDs bekommen
        return loadQuiz(res.quiz_id).then(function (loaded) {
          quiz = loaded;
          message = { text: 'gespeichert ✓', error: false };
          render();
        });
      });
    }, function () {
      saving = false;
      message = { text: 'keine verbindung – nicht gespeichert. bitte nochmal versuchen.', error: true };
      updateStatus();
    });
  }

  window.addEventListener('beforeunload', function (ev) {
    if (dirty) { ev.preventDefault(); ev.returnValue = ''; }
  });

  // -------------------------------------------------------------------------
  // Bilder: beim Hochladen im Browser verkleinern, je eine große Datei für den
  // Presenter und eine kleine fürs Handy. Kein Base64, nichts im Repository.
  // -------------------------------------------------------------------------

  var MAX_IMAGES = 6;
  var IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
  var EXTENSIONS = { 'image/webp': 'webp', 'image/png': 'png', 'image/jpeg': 'jpg' };

  function uuid() {
    if (crypto.randomUUID) return crypto.randomUUID();
    var b = new Uint8Array(16);
    crypto.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var hex = Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
    return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
  }

  function scaled(bitmap, maxEdge) {
    var scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
    var canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return canvas;
  }

  function toBlob(canvas, type) {
    return new Promise(function (resolve) { canvas.toBlob(resolve, type, 0.85); });
  }

  // Liefert { path } der großen Datei; die kleine heißt gleich mit "_m".
  async function uploadImage(file) {
    if (IMAGE_TYPES.indexOf(file.type) < 0) throw new Error('nur jpg, png oder webp.');
    var bitmap = await createImageBitmap(file);
    var large = scaled(bitmap, 1920);
    var small = scaled(bitmap, 900);

    // WebP ist am kleinsten; kann der Browser es nicht erzeugen, bleibt das Ursprungsformat.
    var type = 'image/webp';
    var largeBlob = await toBlob(large, type);
    if (!largeBlob || largeBlob.type !== type) {
      type = file.type === 'image/png' ? 'image/png' : 'image/jpeg';
      largeBlob = await toBlob(large, type);
    }
    var smallBlob = await toBlob(small, type);
    if (!largeBlob || !smallBlob) throw new Error('das bild konnte nicht verarbeitet werden.');

    var path = uuid() + '.' + EXTENSIONS[type];
    var bucket = client.storage.from(TL.IMAGE_BUCKET);
    var options = { contentType: type, cacheControl: '31536000', upsert: false };
    var results = await Promise.all([
      bucket.upload(path, largeBlob, options),
      bucket.upload(TL.mobileImage(path), smallBlob, options)
    ]);
    if (results[0].error || results[1].error) {
      bucket.remove([path, TL.mobileImage(path)]);
      throw new Error('hochladen fehlgeschlagen.');
    }
    uploaded.push(path);
    return path;
  }

  function removeFiles(paths) {
    if (!paths.length) return Promise.resolve();
    var files = [];
    paths.forEach(function (p) { files.push(p, TL.mobileImage(p)); });
    // Aufräumen ist nachrangig: ein Fehler lässt höchstens ungenutzte Dateien zurück.
    return client.storage.from(TL.IMAGE_BUCKET).remove(files).then(function () {}, function () {});
  }

  // Nach dem Speichern: löscht, was laut Server kein Quiz mehr verwendet, und
  // Bilder, die hochgeladen, aber vor dem Speichern wieder entfernt wurden.
  function cleanupImages(removed, keepUploads) {
    var used = {};
    quiz.items.forEach(function (it) { itemFiles(it).forEach(function (p) { used[p] = true; }); });
    var orphans = keepUploads ? [] : uploaded.filter(function (p) { return !used[p]; });
    uploaded = uploaded.filter(function (p) { return used[p]; });
    return removeFiles(removed.concat(orphans));
  }

  function pickImage(item, replaceIndex) {
    var input = h('input', { type: 'file', accept: IMAGE_TYPES.join(',') });
    input.addEventListener('change', function () {
      var file = input.files[0];
      if (!file) return;
      uploading++;
      message = null;
      updateStatus();
      uploadImage(file).then(function (path) {
        if (replaceIndex === undefined) item.images.push(path);
        else item.images[replaceIndex] = path;
        dirty = true;
      }, function (e) {
        message = { text: e && e.message ? e.message : 'hochladen fehlgeschlagen.', error: true };
      }).then(function () {
        uploading--;
        render();
      });
    });
    input.click();
  }

  // -------------------------------------------------------------------------
  // Video und Audio: laufen nur auf dem Presenter. Die Dateien werden
  // unverändert hochgeladen (keine Umwandlung im Browser).
  // -------------------------------------------------------------------------

  var MEDIA_TYPES = {
    video: {
      ext: { mp4: 'video/mp4', webm: 'video/webm' }, maxMb: 50,
      hint: 'mp4 oder webm, höchstens 50 MB'
    },
    audio: {
      ext: { mp3: 'audio/mpeg', m4a: 'audio/mp4', wav: 'audio/wav', ogg: 'audio/ogg' }, maxMb: 15,
      hint: 'mp3, m4a, wav oder ogg, höchstens 15 MB'
    }
  };
  var MAX_CLIPS = 6;
  var LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  function emptyMedia() { return { video: null, audio: [], image_labels: false }; }

  // bringt gespeicherte oder importierte Angaben in die Form, mit der der Editor arbeitet
  function readMedia(value) {
    var m = emptyMedia();
    if (!value || typeof value !== 'object') return m;
    if (value.video && typeof value.video.path === 'string') {
      m.video = { path: value.video.path, loop: !!value.video.loop };
    }
    if (Array.isArray(value.audio)) {
      m.audio = value.audio.filter(function (a) { return a && typeof a.path === 'string'; }).map(function (a) {
        return { path: a.path, loop: !!a.loop, volume: typeof a.volume === 'number' ? a.volume : 1 };
      });
    }
    m.image_labels = !!value.image_labels;
    return m;
  }

  function writeMedia(item) {
    var m = item.media;
    var out = {};
    if (m.video) out.video = { path: m.video.path, loop: m.video.loop };
    if (m.audio.length) {
      out.audio = m.audio.map(function (a) { return { path: a.path, loop: a.loop, volume: a.volume }; });
    }
    if (item.kind !== 'slide' && m.image_labels) out.image_labels = true;
    return out;
  }

  // alle Dateien eines Eintrags (zum Aufräumen)
  function itemFiles(item) {
    var files = item.images.slice();
    if (item.media.video) files.push(item.media.video.path);
    item.media.audio.forEach(function (a) { files.push(a.path); });
    return files;
  }

  async function uploadMedia(file, group) {
    var spec = MEDIA_TYPES[group];
    var ext = (file.name.split('.').pop() || '').toLowerCase();
    if (!spec.ext[ext]) throw new Error('nur ' + spec.hint + '.');
    if (file.size > spec.maxMb * 1024 * 1024) throw new Error('die datei ist zu groß (' + spec.hint + ').');
    var path = uuid() + '.' + ext;
    var res = await client.storage.from(TL.IMAGE_BUCKET).upload(path, file, {
      contentType: spec.ext[ext], cacheControl: '31536000', upsert: false
    });
    if (res.error) throw new Error('hochladen fehlgeschlagen.');
    uploaded.push(path);
    return path;
  }

  function pickMedia(group, onDone) {
    var spec = MEDIA_TYPES[group];
    var input = h('input', {
      type: 'file',
      accept: Object.keys(spec.ext).map(function (e) { return '.' + e; }).join(',')
    });
    input.addEventListener('change', function () {
      var file = input.files[0];
      if (!file) return;
      uploading++;
      message = null;
      updateStatus();
      uploadMedia(file, group).then(function (path) {
        onDone(path);
        dirty = true;
      }, function (e) {
        message = { text: e && e.message ? e.message : 'hochladen fehlgeschlagen.', error: true };
      }).then(function () {
        uploading--;
        render();
      });
    });
    input.click();
  }

  function checkbox(label, checked, onChange) {
    var input = h('input', { type: 'checkbox', disabled: !!lockedBy });
    input.checked = !!checked;
    input.addEventListener('change', function () { onChange(input.checked); setDirty(); });
    return h('label', { class: 'ed-check' }, input, ' ' + label);
  }

  function viewMedia(item) {
    var isSlide = item.kind === 'slide';
    var m = item.media;

    var video;
    if (m.video) {
      video = h('div', { class: 'ed-media' },
        h('video', { class: 'ed-video', src: TL.imageUrl(m.video.path), controls: true, preload: 'metadata' }),
        h('div', { class: 'ed-image-tools' },
          checkbox('loop', m.video.loop, function (v) { m.video.loop = v; }),
          iconButton('ersetzen', 'video ersetzen', function () {
            pickMedia('video', function (path) { m.video = { path: path, loop: m.video.loop }; });
          }),
          iconButton('✕', 'video entfernen', function () { m.video = null; setDirty(); render(); })));
    } else {
      video = iconButton('+ video', 'video hinzufügen (' + MEDIA_TYPES.video.hint + ')', function () {
        pickMedia('video', function (path) { m.video = { path: path, loop: isSlide }; });
      });
    }

    var sounds = m.audio.map(function (a, index) {
      var player = h('audio', { class: 'ed-audio', src: TL.imageUrl(a.path), controls: true, preload: 'metadata' });
      player.volume = a.volume;
      player.loop = a.loop;
      var volume = h('input', {
        type: 'range', min: '0', max: '100', step: '5', value: String(Math.round(a.volume * 100)),
        'aria-label': 'lautstärke', disabled: !!lockedBy,
        oninput: function () {
          a.volume = parseInt(volume.value, 10) / 100;
          player.volume = a.volume;
          setDirty();
        }
      });
      return h('li', { class: 'ed-sound' },
        isSlide ? null : h('span', { class: 'ed-clip-letter' }, LETTERS.charAt(index)),
        player,
        h('div', { class: 'ed-image-tools' },
          h('label', { class: 'ed-check' }, 'lautstärke ', volume),
          checkbox('loop', a.loop, function (v) { a.loop = v; player.loop = v; }),
          isSlide ? null : iconButton('↑', 'clip nach oben', function () { move(m.audio, index, -1); }, index === 0),
          isSlide ? null : iconButton('↓', 'clip nach unten', function () { move(m.audio, index, 1); }, index === m.audio.length - 1),
          iconButton('ersetzen', 'audio ersetzen', function () {
            pickMedia('audio', function (path) { m.audio[index] = { path: path, loop: a.loop, volume: a.volume }; });
          }),
          iconButton('✕', 'audio entfernen', function () { m.audio.splice(index, 1); setDirty(); render(); })));
    });

    var canAddSound = m.audio.length < (isSlide ? 1 : MAX_CLIPS);

    return h('div', { class: 'ed-media-wrap' },
      !isSlide && item.images.length > 1
        ? checkbox('bilder auf dem presenter mit A, B, C beschriften', m.image_labels, function (v) { m.image_labels = v; })
        : null,
      video,
      sounds.length ? h('ul', { class: 'ed-sounds' }, sounds) : null,
      canAddSound ? iconButton(isSlide ? '+ sound' : '+ audio-clip',
        'audio hinzufügen (' + MEDIA_TYPES.audio.hint + ')', function () {
          // Sound einer Slide läuft als Schleife; Clips einer Frage spielen einmal
          pickMedia('audio', function (path) { m.audio.push({ path: path, loop: isSlide, volume: 1 }); });
        }) : null,
      h('p', { class: 'host-meta' }, isSlide
        ? 'video und sound starten automatisch mit der slide und stoppen beim verlassen.'
        : 'video und clips werden auf dem presenter von hand gestartet (klick oder taste A, B, C …). auf den handys erscheint nichts davon.'));
  }

  function viewImages(item) {
    var last = item.images.length - 1;
    var thumbs = item.images.map(function (path, index) {
      return h('li', { class: 'ed-image' },
        h('img', { src: TL.imageUrl(TL.mobileImage(path)), alt: 'bild ' + (index + 1) }),
        h('div', { class: 'ed-image-tools' },
          iconButton('←', 'bild nach vorn', function () { move(item.images, index, -1); }, index === 0),
          iconButton('→', 'bild nach hinten', function () { move(item.images, index, 1); }, index === last),
          iconButton('ersetzen', 'bild ersetzen', function () { pickImage(item, index); }),
          iconButton('✕', 'bild entfernen', function () {
            item.images.splice(index, 1);
            setDirty();
            render();
          })));
    });
    return h('div', { class: 'ed-images-wrap' },
      thumbs.length ? h('ul', { class: 'ed-images' }, thumbs) : null,
      item.images.length < MAX_IMAGES
        ? iconButton('+ bild', 'bild hinzufügen (jpg, png, webp), höchstens ' + MAX_IMAGES, function () { pickImage(item); })
        : null);
  }

  // -------------------------------------------------------------------------
  // Export und Import (nur Storage-Pfade, keine eingebetteten Bilder)
  // -------------------------------------------------------------------------

  function exportQuiz() {
    var data = payload(false);
    data.items.forEach(function (it) {
      delete it.id;
      if (it.options) it.options.forEach(function (o) { delete o.id; });
    });
    var file = { format: 'toericht-quiz', version: 2, title: data.title, items: data.items };
    var url = URL.createObjectURL(new Blob([JSON.stringify(file, null, 2)], { type: 'application/json' }));
    var link = h('a', { href: url, download: (quiz.title || 'quiz').replace(/[^\wäöüß-]+/gi, '_') + '.json' });
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  function importImages(value) {
    return (Array.isArray(value) ? value : []).filter(function (p) { return typeof p === 'string'; }).slice(0, MAX_IMAGES);
  }

  // Liest Version 2 (items) und Version 1 (questions, nur Fragen).
  // Ein Import wird immer ein neues Quiz, nie ein Überschreiben des geöffneten.
  function importQuiz(file) {
    file.text().then(function (text) {
      var data = JSON.parse(text);
      var list = data && (Array.isArray(data.items) ? data.items : data.questions);
      if (!data || data.format !== 'toericht-quiz' || !Array.isArray(list)) throw new Error('format');
      quiz = {
        id: null,
        title: String(data.title || 'importiertes quiz'),
        items: list.map(function (it) {
          if (it.kind === 'leaderboard') return newLeaderboard();
          if (it.kind === 'slide') {
            return {
              id: null, kind: 'slide', heading: String(it.heading || ''), text: String(it.text || ''),
              images: importImages(it.images), media: readMedia(it.media)
            };
          }
          return {
            id: null, kind: it.kind === 'poll' ? 'poll' : 'question',
            text: String(it.text || ''),
            max_selections: parseInt(it.max_selections, 10) || 1,
            images: importImages(it.images), media: readMedia(it.media),
            options: (Array.isArray(it.options) ? it.options : []).map(function (o) {
              return { id: null, label: String(o.label || ''), points: parseInt(o.points, 10) || 0 };
            })
          };
        })
      };
      lockedBy = null;
      dirty = true;
      message = { text: 'importiert als neues quiz – noch nicht gespeichert.', error: false };
      history.replaceState(null, '', '?new');
      render();
    }).catch(function () {
      message = { text: 'diese datei ist kein exportiertes quiz.', error: true };
      updateStatus();
    });
  }

  // -------------------------------------------------------------------------
  // Darstellung
  // -------------------------------------------------------------------------

  function move(list, index, delta) {
    var target = index + delta;
    if (target < 0 || target >= list.length) return;
    var item = list.splice(index, 1)[0];
    list.splice(target, 0, item);
    setDirty();
    render();
  }

  function iconButton(label, title, onclick, disabled) {
    return h('button', {
      class: 'host-btn host-btn-small', type: 'button', title: title, 'aria-label': title,
      disabled: disabled || !!lockedBy, onclick: onclick
    }, label);
  }

  // Zeigt pro Antwort, wie sie später aufgelöst wird (grün / gelb / rot).
  function refreshTiers(q, list) {
    if (q.kind === 'poll') return;
    var tiers = TL.tiers(q.options.map(function (o) { return o.points; }));
    Array.prototype.forEach.call(list.children, function (li, i) {
      li.className = 'ed-option is-' + tiers[i];
      li.firstChild.textContent = TL.TIER_MARKS[tiers[i]];
      li.firstChild.title = { best: 'grün: höchste punktzahl', good: 'gelb: gibt punkte', bad: 'rot: keine punkte' }[tiers[i]];
    });
  }

  function viewOption(q, o, index, name) {
    var isPoll = q.kind === 'poll';
    var label = h('input', {
      class: 'ed-input', type: 'text', maxlength: '200', value: o.label,
      placeholder: 'antwort ' + (index + 1), 'aria-label': name + ', antwort ' + (index + 1),
      disabled: !!lockedBy,
      oninput: function () { o.label = label.value; setDirty(); }
    });
    var pointsInput = h('input', {
      class: 'ed-input ed-points', type: 'number', step: '1', value: String(o.points),
      'aria-label': 'punkte für antwort ' + (index + 1), disabled: !!lockedBy,
      oninput: function () {
        var v = parseInt(pointsInput.value, 10);
        o.points = isNaN(v) ? 0 : v;
        setDirty();
        refreshTiers(q, pointsInput.closest('ul'));
      }
    });
    return h('li', { class: 'ed-option' },
      h('span', { class: 'ed-tier', 'aria-hidden': 'true', hidden: isPoll }),
      label,
      isPoll ? null : h('span', { class: 'ed-points-wrap' }, h('span', { class: 'ed-points-label' }, 'punkte'), pointsInput),
      iconButton('↑', 'antwort nach oben', function () { move(q.options, index, -1); }, index === 0),
      iconButton('↓', 'antwort nach unten', function () { move(q.options, index, 1); }, index === q.options.length - 1),
      iconButton('✕', 'antwort löschen', function () {
        q.options.splice(index, 1);
        if (q.max_selections > q.options.length) q.max_selections = Math.max(1, q.options.length);
        setDirty();
        render();
      }, q.options.length <= 2));
  }

  // Kopfzeile eines Eintrags: Name, verschieben, löschen
  function itemHead(name, index) {
    return h('div', { class: 'ed-question-head' },
      h('span', { class: 'ed-number' }, name),
      iconButton('↑', name + ' nach oben', function () { move(quiz.items, index, -1); }, index === 0),
      iconButton('↓', name + ' nach unten', function () { move(quiz.items, index, 1); }, index === quiz.items.length - 1),
      iconButton('löschen', name + ' löschen', function () {
        if (!window.confirm(name + ' löschen?')) return;
        quiz.items.splice(index, 1);
        setDirty();
        render();
      }));
  }

  function viewQuestion(q, index, number) {
    var isPoll = q.kind === 'poll';
    var name = isPoll ? 'umfrage' : 'frage ' + number;

    var kind = h('select', {
      class: 'ed-input ed-type', 'aria-label': 'art von ' + name, disabled: !!lockedBy,
      onchange: function () {
        q.kind = kind.value;
        setDirty();
        render();
      }
    },
      h('option', { value: 'question', selected: !isPoll }, 'quizfrage – punkte und antwortzeit zählen zur wertung'),
      h('option', { value: 'poll', selected: isPoll }, 'umfrage – keine punkte, keine zeitwertung'));
    var text = h('textarea', {
      class: 'ed-input ed-text', rows: '2', maxlength: '500', placeholder: 'fragetext',
      'aria-label': 'text von ' + name, disabled: !!lockedBy,
      oninput: function () { q.text = text.value; setDirty(); }
    });
    text.value = q.text;

    var multi = q.max_selections > 1;
    var type = h('select', {
      class: 'ed-input ed-type', 'aria-label': 'antworttyp von ' + name, disabled: !!lockedBy,
      onchange: function () {
        q.max_selections = type.value === 'multi' ? Math.min(2, q.options.length) : 1;
        setDirty();
        render();
      }
    },
      h('option', { value: 'single', selected: !multi }, 'eine antwort'),
      h('option', { value: 'multi', selected: multi }, 'mehrere antworten'));

    var max = null;
    if (multi) {
      var maxInput = h('input', {
        class: 'ed-input ed-points', type: 'number', min: '2', max: String(q.options.length), step: '1',
        value: String(q.max_selections), id: 'ed-max-' + index, disabled: !!lockedBy,
        oninput: function () {
          var v = parseInt(maxInput.value, 10);
          if (!isNaN(v)) { q.max_selections = Math.max(2, Math.min(q.options.length, v)); setDirty(); }
        }
      });
      max = h('label', { class: 'ed-max', for: 'ed-max-' + index }, 'höchstens wählbar ', maxInput);
    }

    var list = h('ul', { class: 'ed-options' }, q.options.map(function (o, i) { return viewOption(q, o, i, name); }));
    refreshTiers(q, list);

    return h('li', { class: 'host-panel ed-question' + (isPoll ? ' ed-poll' : '') },
      itemHead(name, index),
      kind,
      text,
      viewImages(q),
      viewMedia(q),
      h('div', { class: 'ed-row' }, type, max),
      isPoll ? null : h('div', { class: 'ed-option-head' }, h('span'), h('span', null, 'antwort'), h('span', null, 'punkte')),
      list,
      iconButton('+ antwort', 'antwort hinzufügen', function () {
        q.options.push(newOption());
        setDirty();
        render();
      }));
  }

  function viewSlide(s, index) {
    var heading = h('input', {
      class: 'ed-input ed-text', type: 'text', maxlength: '200', value: s.heading,
      placeholder: 'überschrift (optional)', 'aria-label': 'überschrift der slide', disabled: !!lockedBy,
      oninput: function () { s.heading = heading.value; setDirty(); }
    });
    var text = h('textarea', {
      class: 'ed-input ed-text ed-gap', rows: '3', maxlength: '1000', placeholder: 'text (optional)',
      'aria-label': 'text der slide', disabled: !!lockedBy,
      oninput: function () { s.text = text.value; setDirty(); }
    });
    text.value = s.text;

    return h('li', { class: 'host-panel ed-question ed-slide' },
      itemHead('slide', index),
      h('p', { class: 'host-meta' }, 'erscheint nur auf dem presenter. keine antworten, keine punkte.'),
      heading, text,
      viewImages(s),
      viewMedia(s));
  }

  function viewLeaderboard(index) {
    return h('li', { class: 'host-panel ed-question ed-board' },
      itemHead('zwischenstand', index),
      h('p', { class: 'host-meta' }, 'zeigt hier die aktuelle rangliste auf presenter und handys. ' +
        'der host kommt mit „weiter" zum nächsten eintrag.'));
  }

  function addItem(item) {
    quiz.items.push(item);
    setDirty();
    render();
    var fields = app.querySelectorAll('.ed-question:last-child .ed-text');
    if (fields.length) fields[0].focus();
  }

  function render() {
    var title = h('input', {
      class: 'live-input ed-title', type: 'text', maxlength: '200', value: quiz.title,
      placeholder: 'titel des quiz', 'aria-label': 'titel des quiz', disabled: !!lockedBy,
      oninput: function () { quiz.title = title.value; setDirty(); }
    });

    statusEl = h('span', { class: 'ed-status', role: 'status' });
    saveButton = h('button', {
      class: 'host-btn host-btn-primary', type: 'button',
      onclick: function () { save(payload(true)); }
    }, 'speichern');

    var fileInput = h('input', {
      type: 'file', accept: 'application/json,.json', hidden: true,
      onchange: function () {
        if (!fileInput.files[0]) return;
        if (dirty && !window.confirm('ungespeicherte änderungen gehen verloren. trotzdem importieren?')) return;
        importQuiz(fileInput.files[0]);
      }
    });

    var number = 0;
    var items = quiz.items.map(function (it, index) {
      if (it.kind === 'leaderboard') return viewLeaderboard(index);
      if (it.kind === 'slide') return viewSlide(it, index);
      // nur gewertete Fragen werden durchnummeriert
      if (it.kind === 'question') number++;
      return viewQuestion(it, index, number);
    });

    TL.show(app,
      h('header', { class: 'host-head ed-head' },
        h('a', { class: 'host-btn', href: '../' }, '← übersicht'),
        h('h1', { class: 'host-title' }, quiz.id ? 'quiz bearbeiten' : 'neues quiz'),
        statusEl, saveButton),

      lockedBy ? h('p', { class: 'host-warn' },
        'gesperrt: für dieses quiz läuft die session ' + lockedBy +
        '. bearbeiten geht erst, wenn sie beendet oder in der übersicht gelöscht ist.') : null,

      title,

      h('div', { class: 'ed-tools' },
        h('button', {
          class: 'host-btn host-btn-small', type: 'button', disabled: !quiz.id,
          onclick: function () {
            var copy = payload(false);
            copy.title = quiz.title + ' (kopie)';
            save(copy, true);
          }
        }, 'duplizieren'),
        h('button', { class: 'host-btn host-btn-small', type: 'button', onclick: exportQuiz }, 'exportieren'),
        h('button', { class: 'host-btn host-btn-small', type: 'button', onclick: function () { fileInput.click(); } }, 'importieren'),
        fileInput,
        h('button', {
          class: 'host-btn host-btn-small host-btn-danger', type: 'button', disabled: !quiz.id,
          onclick: function () {
            if (!window.confirm('das quiz „' + quiz.title + '" endgültig löschen?')) return;
            TL.rpc('host_delete_quiz', { p_quiz_id: quiz.id }).then(function (res) {
              if (!res.ok) {
                message = { text: errorText(res), error: true };
                updateStatus();
                return;
              }
              dirty = false;
              return removeFiles(res.removed_images || []).then(function () { location.href = '../'; });
            }, function () {
              message = { text: 'keine verbindung – nicht gelöscht.', error: true };
              updateStatus();
            });
          }
        }, 'quiz löschen')),
      h('p', { class: 'host-meta' },
        'die exportierte datei enthält die punktwerte und nur die pfade von bildern, videos und audio, nicht die dateien selbst. ' +
        'bitte nicht ins repository legen oder weitergeben.'),

      h('ol', { class: 'ed-questions' }, items),

      h('div', { class: 'ed-tools' },
        h('button', { class: 'host-btn', type: 'button', disabled: !!lockedBy,
          onclick: function () { addItem(newQuestion()); } }, '+ frage'),
        h('button', { class: 'host-btn', type: 'button', disabled: !!lockedBy,
          onclick: function () { addItem(newSlide()); } }, '+ slide'),
        h('button', { class: 'host-btn', type: 'button', disabled: !!lockedBy,
          onclick: function () { addItem(newLeaderboard()); } }, '+ zwischenstand')));

    updateStatus();
  }

  // -------------------------------------------------------------------------
  // Start
  // -------------------------------------------------------------------------

  function fail(text) {
    TL.show(app,
      h('p', { class: 'live-error' }, text),
      h('a', { class: 'host-btn', href: '../' }, '← übersicht'));
  }

  TL.checkHost().then(function (isHost) {
    if (!isHost) {
      TL.show(app,
        h('p', { class: 'live-text' }, 'bitte zuerst in der host-ansicht einloggen.'),
        h('a', { class: 'live-btn', href: '../' }, 'zur host-ansicht'));
      return;
    }
    var id = params.get('q');
    if (!id) {
      quiz = { id: null, title: '', items: [newQuestion()] };
      render();
      return;
    }
    return loadQuiz(id).then(function (loaded) {
      if (!loaded) { fail(ERRORS.QUIZ_NOT_FOUND); return; }
      quiz = loaded;
      render();
    });
  }).catch(function () {
    fail('der editor konnte nicht geladen werden.');
  });
})();
