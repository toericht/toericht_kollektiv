-- töricht live – Selbsttest für Presenter-Medien (Video, Audio) und Punkte in der Auflösung
-- Im Supabase SQL Editor ausführen (nach 010_presenter_media.sql).
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder. Schlägt ein Check
-- fehl, bricht das Skript ab und hinterlässt nichts.
-- Geprüft wird, was der Server ausliefert. Ob Video und Ton im Browser korrekt
-- starten und stoppen, lässt sich hier nicht testen (siehe Browser-Testschritte).

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_s1 uuid; v_q1 uuid; v_p1 uuid; v_q2 uuid;
  v_q1a uuid; v_px uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  v_before jsonb;
  v_after jsonb;
  r jsonb;
  c_img1  constant text := 'aaaaaaaa-1111-4111-8111-111111111111.webp';
  c_img2  constant text := 'aaaaaaaa-2222-4222-8222-222222222222.webp';
  c_video constant text := 'bbbbbbbb-1111-4111-8111-111111111111.mp4';
  c_fire  constant text := 'cccccccc-1111-4111-8111-111111111111.mp3';
  c_clipa constant text := 'cccccccc-2222-4222-8222-222222222222.mp3';
  c_clipb constant text := 'cccccccc-3333-4333-8333-333333333333.wav';
  c_media constant text := '\.(webp|jpg|png|mp4|webm|mp3|m4a|wav|ogg)';
  c_t1 constant text := 'media-token-1-aaaaaaaaaaaaaaaaaaaaaaaaaaa';
  c_t2 constant text := 'media-token-2-bbbbbbbbbbbbbbbbbbbbbbbbbbb';
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';

  -- Rechte: Presenter-Daten und Uploads nur für eingeloggte Hosts
  assert not has_function_privilege('anon', 'public.presenter_get_state(uuid)', 'execute'), 'anon darf presenter_get_state nicht ausführen';
  assert (select count(*) from pg_policies
          where schemaname = 'storage' and tablename = 'objects'
            and policyname in ('quiz_images_host_select', 'quiz_images_host_insert',
                               'quiz_images_host_update', 'quiz_images_host_delete')
            and roles = '{authenticated}'
            and coalesce(qual, '') || coalesce(with_check, '') like '%is_host%') = 4,
    'vier Storage-Regeln, alle nur für Hosts';
  assert (select 'video/mp4' = any (allowed_mime_types) and 'audio/mpeg' = any (allowed_mime_types)
                 and not ('text/html' = any (allowed_mime_types))
          from storage.buckets where id = 'quiz-images'), 'Bucket nimmt Video und Audio an, aber nichts anderes';

  perform set_config('request.jwt.claims', '{}', true);
  assert public.presenter_get_state(gen_random_uuid())->>'error' = 'NOT_HOST', 'presenter_get_state ohne Login';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  -- Validierung der Medien-Angaben
  assert public.host_save_quiz('{"title":"x","items":[{"kind":"slide","heading":"h","media":{"video":{"path":"../x.mp4"}}}]}')->>'error' = 'INVALID_MEDIA', 'ungültiger Videopfad';
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'slide', 'heading', 'h', 'media', jsonb_build_object('video', jsonb_build_object('path', c_img1))))))->>'error' = 'INVALID_MEDIA', 'Bild als Video';
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'slide', 'heading', 'h', 'media', jsonb_build_object('audio', jsonb_build_array(
      jsonb_build_object('path', c_fire), jsonb_build_object('path', c_clipa)))))))->>'error' = 'INVALID_MEDIA', 'Slide mit zwei Sounds';
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'slide', 'heading', 'h', 'media', jsonb_build_object('audio', jsonb_build_array(
      jsonb_build_object('path', c_fire, 'volume', 3)))))))->>'error' = 'INVALID_MEDIA', 'Lautstärke über 1';
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'slide', 'heading', 'h', 'media', jsonb_build_object('audio', 'laut')))))->>'error' = 'INVALID_MEDIA', 'Audio ist keine Liste';
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'question', 'text', 'f', 'max_selections', 1,
      'options', jsonb_build_array(jsonb_build_object('label', 'a', 'points', 1), jsonb_build_object('label', 'b', 'points', 0)),
      'media', jsonb_build_object('audio', (select jsonb_agg(jsonb_build_object('path', c_clipa)) from generate_series(1, 7)))))))->>'error' = 'INVALID_MEDIA', 'sieben Clips';
  assert (select count(*) from public.quizzes where title = 'x') = 0, 'ungültiges Quiz legt nichts an';

  -- Quiz: Slide mit Video + Sound → Frage mit zwei Clips und beschrifteten Bildern → Umfrage mit Video → Frage ohne Medien
  r := public.host_save_quiz(jsonb_build_object(
    'title', '__media_selftest__',
    'items', jsonb_build_array(
      jsonb_build_object('kind', 'slide', 'media', jsonb_build_object(
        'video', jsonb_build_object('path', c_video, 'loop', true),
        'audio', jsonb_build_array(jsonb_build_object('path', c_fire, 'loop', true, 'volume', 0.4)),
        'image_labels', true, 'unbekannt', 'wird verworfen')),
      jsonb_build_object('kind', 'question', 'text', 'Welcher Schrei?', 'max_selections', 1,
        'images', jsonb_build_array(c_img1, c_img2),
        'media', jsonb_build_object('image_labels', true, 'audio', jsonb_build_array(
          jsonb_build_object('path', c_clipa), jsonb_build_object('path', c_clipb, 'loop', false, 'volume', 1))),
        'options', jsonb_build_array(
          jsonb_build_object('label', 'Final Girl', 'points', 3),
          jsonb_build_object('label', 'Killer', 'points', 1),
          jsonb_build_object('label', 'Victim', 'points', -2))),
      jsonb_build_object('kind', 'poll', 'text', 'Wohin?', 'max_selections', 1,
        'media', jsonb_build_object('video', jsonb_build_object('path', c_video)),
        'options', jsonb_build_array(jsonb_build_object('label', 'X'), jsonb_build_object('label', 'Y'))),
      jsonb_build_object('kind', 'question', 'text', 'Ohne Medien', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 2), jsonb_build_object('label', 'B', 'points', 0))))));
  assert (r->>'ok')::boolean, 'Quiz mit Medien speichern (Slide nur mit Video und Sound ist erlaubt): ' || r::text;
  v_quiz := (r->>'quiz_id')::uuid;

  select id into v_s1 from public.questions where quiz_id = v_quiz and position = 1;
  select id into v_q1 from public.questions where quiz_id = v_quiz and position = 2;
  select id into v_p1 from public.questions where quiz_id = v_quiz and position = 3;
  select id into v_q2 from public.questions where quiz_id = v_quiz and position = 4;
  select id into v_q1a from public.answer_options where question_id = v_q1 and position = 1;
  select id into v_px from public.answer_options where question_id = v_p1 and position = 1;

  -- gespeichert wird nur die geprüfte, vereinheitlichte Form
  assert (select media from public.questions where id = v_s1) = jsonb_build_object(
    'video', jsonb_build_object('path', c_video, 'loop', true),
    'audio', jsonb_build_array(jsonb_build_object('path', c_fire, 'loop', true, 'volume', 0.4))),
    'Slide-Medien vereinheitlicht, unbekannte Angaben verworfen: ' || (select media::text from public.questions where id = v_s1);
  assert (select media#>>'{audio,0,volume}' from public.questions where id = v_q1) = '1', 'Standard-Lautstärke 1';
  assert (select (media->>'image_labels')::boolean from public.questions where id = v_q1), 'Bildbeschriftung gespeichert';
  assert (select media from public.questions where id = v_q2) = '{}'::jsonb, 'Frage ohne Medien bleibt leer';

  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;
  perform public.join_game(v_code, 'M1', c_t1);
  perform public.join_game(v_code, 'M2', c_t2);

  -- 1) Slide mit Video und Sound
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'SLIDE', 'Slide: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert r::text !~ c_media and r::text not like '%media%' and r::text not like '%images%', 'Spieler:in bekommt bei der Slide keine Medien: ' || r::text;
  r := public.presenter_get_state(v_session);
  assert r#>>'{slide,media,video,path}' = c_video and (r#>>'{slide,media,video,loop}')::boolean, 'Presenter: Slide-Video mit Loop';
  assert r#>>'{slide,media,audio,0,path}' = c_fire and (r#>>'{slide,media,audio,0,volume}')::numeric = 0.4, 'Presenter: Slide-Sound mit Lautstärke';
  assert not (r ? 'question') and not (r ? 'leaderboard') and not (r ? 'players'), 'Presenter: bei der Slide nichts anderes';
  assert (select count(*) from public.session_questions where session_id = v_session) = 0, 'Slide mit Medien erzeugt keinen Zeiteintrag';

  -- 2) Frage mit Clips: offen und geschlossen ohne Punkte und Stimmen
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'QUESTION_OPEN', 'Frage: ' || r::text;
  v_ver := (r->>'version')::int;

  r := public.get_state(c_t1);
  assert r::text !~ c_media and r::text not like '%media%' and r::text not like '%images%', 'Spieler:in bekommt bei der Frage keine Medien: ' || r::text;
  assert r::text not like '%points%' and r::text not like '%tier%', 'Spieler:in: offene Frage ohne Punkte';
  assert jsonb_array_length(r#>'{question,options}') = 3, 'Spieler:in sieht Text und Antworten';

  r := public.presenter_get_state(v_session);
  assert jsonb_array_length(r#>'{question,media,audio}') = 2, 'Presenter: zwei Clips';
  assert (r#>>'{question,media,image_labels}')::boolean and jsonb_array_length(r#>'{question,images}') = 2, 'Presenter: zwei beschriftete Bilder';
  assert r::text not like '%points%', 'Presenter: offene Frage ohne Punktwerte: ' || r::text;
  assert not (r#>'{question,options,0}' ? 'count'), 'Presenter: offene Frage ohne Stimmen pro Antwort';
  assert not (r ? 'leaderboard'), 'Presenter: keine Rangliste während der Frage';
  assert r::text not like '%option_ids%' and not (r ? 'players'), 'Presenter: keine einzelnen Antworten, keine Personenliste';

  update public.session_questions set last_opened_at = clock_timestamp() - interval '10 seconds'
  where session_id = v_session and question_id = v_q1;
  assert (public.submit_answer(c_t1, v_q1, array[v_q1a], 1)->>'ok')::boolean, 'M1 antwortet';
  r := public.presenter_get_state(v_session);
  assert (r->>'answered_count')::int = 1, 'Presenter: Zahl der Antworten';
  assert r::text not like '%points%', 'Presenter: weiterhin keine Punktwerte';

  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  assert public.presenter_get_state(v_session)::text not like '%points%', 'Presenter: geschlossene Frage ohne Punktwerte';
  assert public.get_state(c_t2)::text not like '%points%', 'Spieler:in: geschlossene Frage ohne Punktwerte';

  -- 3) Auflösung: Punkte pro Antwort, Stimmen, Basis für Prozent
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.presenter_get_state(v_session);
  assert (r#>>'{question,options,0,points}')::int = 3 and (r#>>'{question,options,1,points}')::int = 1
     and (r#>>'{question,options,2,points}')::int = -2, 'Presenter: Punkte pro Antwort in der Auflösung: ' || (r->'question')::text;
  assert (r#>>'{question,options,0,count}')::int = 1 and (r#>>'{question,options,2,count}')::int = 0, 'Presenter: Stimmen pro Antwort';
  assert (r->>'answered_count')::int = 1, 'Presenter: Basis für Prozent';
  r := public.get_state(c_t1);
  assert r::text !~ c_media, 'Spieler:in bekommt auch in der Auflösung keine Medien';
  assert r#>>'{results,0,tier}' = 'best' and (r->>'my_question_score')::int = 3, 'Spieler:in: Farbstufe und eigene Punkte wie bisher';

  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_before
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;

  -- 4) Umfrage mit Video: in der Auflösung Stimmen, aber nie Punkte
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  r := public.presenter_get_state(v_session);
  assert r#>>'{question,kind}' = 'poll' and r#>>'{question,media,video,path}' = c_video, 'Presenter: Umfrage mit Video';
  assert not (r#>>'{question,media,video,loop}')::boolean, 'Loop ist ohne Angabe aus';
  assert public.get_state(c_t2)::text !~ c_media, 'Spieler:in bekommt bei der Umfrage keine Medien';
  assert (public.submit_answer(c_t2, v_p1, array[v_px], 1)->>'ok')::boolean, 'M2 stimmt ab';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.presenter_get_state(v_session);
  assert (r#>>'{question,options,0,count}')::int = 1, 'Presenter: Stimmen der Umfrage';
  assert r::text not like '%points%', 'Presenter: Umfrage ohne Punkte: ' || r::text;

  -- Slide, Medien und Umfrage haben die Wertung nicht verändert
  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_after
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;
  assert v_after = v_before, 'Wertung unverändert: ' || v_before::text || ' / ' || v_after::text;
  assert (select count(*) from public.session_questions where session_id = v_session) = 1, 'ein Zeiteintrag für die eine gespielte Frage';

  -- 5) Rangliste erst im Leaderboard
  r := public.host_action(v_session, v_ver, 'SHOW_LEADERBOARD');
  v_ver := (r->>'version')::int;
  r := public.presenter_get_state(v_session);
  assert r#>>'{leaderboard,0,name}' = 'M1' and (r#>>'{leaderboard,0,score}')::int = 3, 'Presenter: Rangliste: ' || (r->'leaderboard')::text;
  assert not (r ? 'question') and not (r ? 'slide'), 'Presenter: im Leaderboard keine Frage und keine Medien';

  -- 6) Frage ohne Medien funktioniert wie bisher
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  r := public.presenter_get_state(v_session);
  assert r#>'{question,media}' = '{}'::jsonb and r#>'{question,images}' = '[]'::jsonb, 'Presenter: Frage ohne Medien';
  assert (r->>'question_number')::int = 2 and (r->>'question_total')::int = 2, 'Presenter: Frage 2 von 2';
  r := public.host_action(v_session, v_ver, 'END');

  -- 7) Aufräumen meldet auch Video und Audio; geteilte Dateien bleiben
  assert (public.host_delete_session(v_session)->>'ok')::boolean, 'Session löschen';
  r := public.host_save_quiz(jsonb_build_object(
    'id', v_quiz, 'title', '__media_selftest__',
    'items', jsonb_build_array(
      jsonb_build_object('id', v_s1, 'kind', 'slide', 'heading', 'ohne Ton', 'media', jsonb_build_object(
        'video', jsonb_build_object('path', c_video, 'loop', true))),
      jsonb_build_object('id', v_q2, 'kind', 'question', 'text', 'Ohne Medien', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 2), jsonb_build_object('label', 'B', 'points', 0))))));
  assert (r->>'ok')::boolean, 'Quiz kürzen: ' || r::text;
  assert r->'removed_images' @> to_jsonb(array[c_fire, c_clipa, c_clipb, c_img1, c_img2])
     and jsonb_array_length(r->'removed_images') = 5,
    'entfernte Dateien werden gemeldet, das weiter benutzte Video nicht: ' || (r->'removed_images')::text;
  r := public.host_delete_quiz(v_quiz);
  assert (r->>'ok')::boolean and r->'removed_images' = to_jsonb(array[c_video]), 'Quiz löschen meldet das Video: ' || r::text;
end;
$$;

select 'Medien Selbsttest: alle Checks bestanden' as ergebnis;
