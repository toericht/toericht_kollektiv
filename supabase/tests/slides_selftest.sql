-- töricht live – Selbsttest für Slides und Bilder
-- Im Supabase SQL Editor ausführen (nach 010_presenter_media.sql). Dauert ca. 1 Sekunde.
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder. Schlägt ein Check
-- fehl, bricht das Skript ab und hinterlässt nichts.

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_s1 uuid; v_q1 uuid; v_s2 uuid; v_q2 uuid; v_s3 uuid;
  v_q1a uuid; v_q2a uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  v_time bigint;
  r jsonb;
  c_img1 constant text := '11111111-1111-4111-8111-111111111111.webp';
  c_img2 constant text := '22222222-2222-4222-8222-222222222222.jpg';
  c_img3 constant text := '33333333-3333-4333-8333-333333333333.png';
  c_t1 constant text := 'slides-token-1-aaaaaaaaaaaaaaaaaaaaaaaaaa';
  c_t2 constant text := 'slides-token-2-bbbbbbbbbbbbbbbbbbbbbbbbbb';
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  -- Validierung
  assert public.host_save_quiz('{"title":"x","items":[{"kind":"slide","heading":"h","options":[{"label":"a","points":1},{"label":"b","points":0}]}]}')->>'error' = 'INVALID_SLIDE', 'Slide mit Antworten';
  assert public.host_save_quiz('{"title":"x","items":[{"kind":"slide","heading":"  ","text":""}]}')->>'error' = 'EMPTY_SLIDE', 'leere Slide';
  assert public.host_save_quiz('{"title":"x","items":[{"kind":"quizfrage","text":"f"}]}')->>'error' = 'INVALID_ITEM', 'unbekannte Art';
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'slide', 'heading', 'h', 'images',
      jsonb_build_array(c_img1, c_img2, c_img3, c_img1, c_img2, c_img3, c_img1)))))->>'error' = 'INVALID_IMAGES', 'mehr als sechs Bilder';
  assert public.host_save_quiz('{"title":"x","items":[{"kind":"slide","heading":"h","images":["../geheim.png"]}]}')->>'error' = 'INVALID_IMAGES', 'ungültiger Bildname';
  assert (select count(*) from public.quizzes where title = 'x') = 0, 'ungültiges Quiz darf nichts anlegen';

  -- ein Quiz nur aus Slides lässt sich speichern, aber nicht spielen
  r := public.host_save_quiz('{"title":"__slides_only__","items":[{"kind":"slide","heading":"nur text"}]}');
  assert (r->>'ok')::boolean, 'Quiz nur aus Slides speichern: ' || r::text;
  assert public.host_create_session((r->>'quiz_id')::uuid)->>'error' = 'QUIZ_EMPTY', 'Quiz ohne Frage startet keine Session';
  assert (public.host_delete_quiz((r->>'quiz_id')::uuid)->>'ok')::boolean, 'Quiz nur aus Slides löschen';

  -- Quiz: Slide → Frage → Slide → Frage → Slide
  r := public.host_save_quiz(jsonb_build_object(
    'title', '__slides_selftest__',
    'items', jsonb_build_array(
      jsonb_build_object('kind', 'slide', 'heading', 'Geheimes Intro', 'text', '', 'images', jsonb_build_array(c_img1)),
      jsonb_build_object('kind', 'question', 'text', 'Frage eins', 'max_selections', 1,
        'images', jsonb_build_array(c_img2, c_img3),
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 5), jsonb_build_object('label', 'B', 'points', 0))),
      jsonb_build_object('kind', 'slide', 'text', 'Zwischentext'),
      jsonb_build_object('kind', 'question', 'text', 'Frage zwei', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 3), jsonb_build_object('label', 'B', 'points', 1))),
      jsonb_build_object('kind', 'slide', 'heading', 'Schluss'))));
  assert (r->>'ok')::boolean, 'Quiz mit Slides speichern: ' || r::text;
  v_quiz := (r->>'quiz_id')::uuid;

  select id into v_s1 from public.questions where quiz_id = v_quiz and position = 1;
  select id into v_q1 from public.questions where quiz_id = v_quiz and position = 2;
  select id into v_s2 from public.questions where quiz_id = v_quiz and position = 3;
  select id into v_q2 from public.questions where quiz_id = v_quiz and position = 4;
  select id into v_s3 from public.questions where quiz_id = v_quiz and position = 5;
  select id into v_q1a from public.answer_options where question_id = v_q1 and position = 1;
  select id into v_q2a from public.answer_options where question_id = v_q2 and position = 1;
  assert (select kind from public.questions where id = v_s1) = 'slide', 'erster Eintrag ist eine Slide';
  assert (select text from public.questions where id = v_s1) = '', 'Slide ohne Text ist erlaubt';
  assert (select count(*) from public.answer_options where question_id in (v_s1, v_s2, v_s3)) = 0, 'Slides haben keine Antworten';
  assert (select image_paths from public.questions where id = v_q1) = array[c_img2, c_img3], 'Bildreihenfolge bleibt erhalten';

  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;
  perform public.join_game(v_code, 'S1', c_t1);
  perform public.join_game(v_code, 'S2', c_t2);

  r := public.host_get_state(v_session);
  assert (r->>'question_total')::int = 2, 'gezählt werden nur Fragen: ' || (r->>'question_total');
  assert r#>>'{next,kind}' = 'slide', 'als Nächstes kommt eine Slide';

  -- 1) Slide: eigener Zustand, kein Inhalt für Spieler:innen, keine Antworten, keine Zeit
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'SLIDE', 'erste Slide: ' || r::text;
  v_ver := (r->>'version')::int;

  r := public.get_state(c_t1);
  assert r#>>'{session,state}' = 'SLIDE', 'Spieler:in sieht Zustand SLIDE';
  assert not (r ? 'question') and not (r ? 'slide'), 'kein Inhalt bei SLIDE: ' || r::text;
  assert r::text not like '%Geheimes Intro%' and r::text not like '%Frage eins%' and r::text not like '%.webp%',
    'weder Slide-Inhalt noch kommende Frage: ' || r::text;

  assert public.submit_answer(c_t1, v_s1, array[v_q1a], 1)->>'error' = 'QUESTION_NOT_OPEN', 'Antwort auf eine Slide';
  assert public.submit_answer(c_t1, v_q1, array[v_q1a], 1)->>'error' = 'QUESTION_NOT_OPEN', 'Antwort auf die kommende Frage';
  assert (select count(*) from public.player_answers where session_id = v_session) = 0, 'keine Antwort gespeichert';
  assert (select count(*) from public.session_questions where session_id = v_session) = 0, 'Slide erzeugt keinen Zeiteintrag';
  assert public.host_action(v_session, v_ver, 'CLOSE')->>'error' = 'INVALID_TRANSITION', 'eine Slide lässt sich nicht schließen';

  r := public.host_get_state(v_session);
  assert r#>>'{slide,heading}' = 'Geheimes Intro', 'Host sieht die Slide: ' || r::text;
  assert r#>>'{slide,images,0}' = c_img1, 'Host sieht das Slide-Bild';
  assert not (r ? 'question') and not (r ? 'answered_count'), 'Slide ist keine Frage';
  assert r#>>'{next,kind}' = 'question', 'als Nächstes kommt eine Frage';

  -- Leaderboard aus der Slide und zurück
  r := public.host_action(v_session, v_ver, 'SHOW_LEADERBOARD');
  assert r->>'state' = 'LEADERBOARD', 'Leaderboard aus Slide: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  assert r->>'state' = 'SLIDE', 'Leaderboard verstecken führt zurück zur Slide: ' || r::text;
  v_ver := (r->>'version')::int;

  -- 2) Frage eins: Zählung ohne Slides, Handy-Bilder, Zeitmessung
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'QUESTION_OPEN', 'Frage eins: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert (r#>>'{question,number}')::int = 1 and (r#>>'{question,total}')::int = 2, 'Frage 1 von 2: ' || (r->'question')::text;
  -- seit 010 laufen Bilder nur noch auf dem Presenter
  assert not (r->'question' ? 'images') and r::text not like '%22222222-2222%', 'Spieler:in bekommt keine Bilder: ' || (r->'question')::text;
  assert r::text not like '%points%' and r::text not like '%tier%', 'offene Frage ohne Punkte und Stufen';
  r := public.host_get_state(v_session);
  assert r#>>'{question,images,0}' = c_img2, 'Host bekommt die große Bildvariante';
  assert r#>>'{question,images,1}' = c_img3, 'Host: zweites Bild in gleicher Reihenfolge';
  assert (r->>'question_number')::int = 1, 'Host: Frage 1';

  update public.session_questions set last_opened_at = clock_timestamp() - interval '10 seconds'
  where session_id = v_session and question_id = v_q1;
  assert (public.submit_answer(c_t1, v_q1, array[v_q1a], 1)->>'ok')::boolean, 'Antwort auf Frage eins';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  assert (select count(*) from public.session_questions where session_id = v_session) = 1, 'ein Zeiteintrag für eine Frage';

  -- 3) Slide zwei: Zeit läuft für niemanden weiter
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'SLIDE', 'zweite Slide: ' || r::text;
  v_ver := (r->>'version')::int;
  select (p->>'time_ms')::bigint into v_time
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p where p->>'name' = 'S2';
  assert v_time between 10000 and 10500, 'S2 hat Frage eins nicht beantwortet: volle Öffnungsdauer, ' || v_time;
  perform pg_sleep(1);
  assert (select (p->>'time_ms')::bigint from jsonb_array_elements(public.host_get_state(v_session)->'players') p
          where p->>'name' = 'S2') = v_time, 'Zeit auf einer Slide zählt nicht';
  assert (select count(*) from public.session_questions where session_id = v_session) = 1, 'weiterhin ein Zeiteintrag';

  -- 4) Frage zwei
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'QUESTION_OPEN', 'Frage zwei: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t2);
  assert (r#>>'{question,number}')::int = 2 and (r#>>'{question,total}')::int = 2, 'Frage 2 von 2';
  update public.session_questions set last_opened_at = clock_timestamp() - interval '4 seconds'
  where session_id = v_session and question_id = v_q2;
  assert (public.submit_answer(c_t2, v_q2, array[v_q2a], 1)->>'ok')::boolean, 'Antwort auf Frage zwei';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;

  -- Ranking wie ohne Slides: S1 5 Punkte (10 s + 4 s unbeantwortet), S2 3 Punkte (10 s + 4 s)
  r := public.host_get_state(v_session);
  assert r#>>'{players,0,name}' = 'S1' and (r#>>'{players,0,score}')::int = 5, 'S1 führt: ' || (r->'players')::text;
  assert (r#>>'{players,0,time_ms}')::bigint between 14000 and 15000, 'S1 Zeit nur aus zwei Fragen: ' || (r->'players')::text;
  assert (r#>>'{players,1,score}')::int = 3, 'S2 hat 3 Punkte';
  assert (r#>>'{players,1,time_ms}')::bigint between 14000 and 15000, 'S2 Zeit nur aus zwei Fragen: ' || (r->'players')::text;
  assert (select count(*) from public.session_questions where session_id = v_session) = 2, 'zwei Zeiteinträge für zwei Fragen';

  -- 5) Schluss-Slide, danach nichts mehr, Finale direkt aus der Slide
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'SLIDE', 'Schluss-Slide: ' || r::text;
  v_ver := (r->>'version')::int;
  assert public.host_get_state(v_session)->'next' = 'null'::jsonb, 'danach kommt nichts mehr';
  assert public.host_action(v_session, v_ver, 'OPEN_NEXT')->>'error' = 'NO_MORE_QUESTIONS', 'kein weiterer Eintrag';
  r := public.host_action(v_session, v_ver, 'SHOW_FINAL');
  assert r->>'state' = 'FINAL_RESULTS', 'Finale aus Slide: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert (r#>>'{me,rank}')::int = 1 and (r#>>'{me,score}')::int = 5, 'S1 gewinnt: ' || (r->'me')::text;
  r := public.host_action(v_session, v_ver, 'END');
  assert r->>'state' = 'ENDED', 'END: ' || r::text;

  -- 6) Bilder aufräumen: nur was kein Quiz mehr verwendet
  assert (public.host_delete_session(v_session)->>'ok')::boolean, 'Session löschen';
  r := public.host_save_quiz(jsonb_build_object(
    'id', v_quiz, 'title', '__slides_selftest__',
    'items', jsonb_build_array(
      jsonb_build_object('id', v_s1, 'kind', 'slide', 'heading', 'Intro ohne Bild'),
      jsonb_build_object('id', v_q1, 'kind', 'question', 'text', 'Frage eins', 'max_selections', 1,
        'images', jsonb_build_array(c_img3),
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 5), jsonb_build_object('label', 'B', 'points', 0))))));
  assert (r->>'ok')::boolean, 'Quiz kürzen: ' || r::text;
  assert r->'removed_images' @> to_jsonb(array[c_img1, c_img2]) and jsonb_array_length(r->'removed_images') = 2,
    'entfernte Bilder werden gemeldet, das behaltene nicht: ' || (r->'removed_images')::text;
  r := public.host_delete_quiz(v_quiz);
  assert (r->>'ok')::boolean and r->'removed_images' = to_jsonb(array[c_img3]), 'Quiz löschen meldet das letzte Bild: ' || r::text;
end;
$$;

select 'Slides Selbsttest: alle Checks bestanden' as ergebnis;
