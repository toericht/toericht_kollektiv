-- töricht live – Selbsttest für Umfragen und bis zu 6 Bilder
-- Im Supabase SQL Editor ausführen (nach 010_presenter_media.sql).
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder. Schlägt ein Check
-- fehl, bricht das Skript ab und hinterlässt nichts.

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_q1 uuid; v_p1 uuid; v_p2 uuid; v_q2 uuid;
  v_q1a uuid; v_q2a uuid;
  v_x uuid; v_y uuid; v_z uuid;
  v_l uuid; v_m uuid; v_n uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  v_before jsonb;
  v_after jsonb;
  v_imgs jsonb;
  r jsonb;
  c_t1 constant text := 'polls-token-1-aaaaaaaaaaaaaaaaaaaaaaaaaaa';
  c_t2 constant text := 'polls-token-2-bbbbbbbbbbbbbbbbbbbbbbbbbbb';
  c_t3 constant text := 'polls-token-3-ccccccccccccccccccccccccccc';
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  -- Bilder: 6 werden angenommen, 7 abgelehnt
  select jsonb_agg(lpad(i::text, 8, '0') || '-1111-4111-8111-111111111111.webp') into v_imgs
  from generate_series(1, 7) as i;
  assert public.host_save_quiz(jsonb_build_object('title', 'x', 'items', jsonb_build_array(
    jsonb_build_object('kind', 'slide', 'heading', 'h', 'images', v_imgs))))->>'error' = 'INVALID_IMAGES', '7 Bilder werden abgelehnt';
  assert (select count(*) from public.quizzes where title = 'x') = 0, 'abgelehntes Quiz legt nichts an';

  -- Quiz: Frage → Umfrage (eine Antwort) → Umfrage (mehrere) → Frage
  r := public.host_save_quiz(jsonb_build_object(
    'title', '__polls_selftest__',
    'items', jsonb_build_array(
      jsonb_build_object('kind', 'question', 'text', 'Frage eins', 'max_selections', 1,
        'images', v_imgs - 6,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 5), jsonb_build_object('label', 'B', 'points', 0))),
      -- Punkte in einer Umfrage werden beim Speichern verworfen
      jsonb_build_object('kind', 'poll', 'text', 'Wohin als Nächstes?', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'X', 'points', 99), jsonb_build_object('label', 'Y'),
          jsonb_build_object('label', 'Z', 'points', -7))),
      jsonb_build_object('kind', 'poll', 'text', 'Was noch?', 'max_selections', 2,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'L'), jsonb_build_object('label', 'M'), jsonb_build_object('label', 'N'))),
      jsonb_build_object('kind', 'question', 'text', 'Frage zwei', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 3), jsonb_build_object('label', 'B', 'points', 1))))));
  assert (r->>'ok')::boolean, 'Quiz mit Umfragen und 6 Bildern speichern: ' || r::text;
  v_quiz := (r->>'quiz_id')::uuid;

  select id into v_q1 from public.questions where quiz_id = v_quiz and position = 1;
  select id into v_p1 from public.questions where quiz_id = v_quiz and position = 2;
  select id into v_p2 from public.questions where quiz_id = v_quiz and position = 3;
  select id into v_q2 from public.questions where quiz_id = v_quiz and position = 4;
  select id into v_q1a from public.answer_options where question_id = v_q1 and position = 1;
  select id into v_q2a from public.answer_options where question_id = v_q2 and position = 1;
  select id into v_x from public.answer_options where question_id = v_p1 and position = 1;
  select id into v_y from public.answer_options where question_id = v_p1 and position = 2;
  select id into v_z from public.answer_options where question_id = v_p1 and position = 3;
  select id into v_l from public.answer_options where question_id = v_p2 and position = 1;
  select id into v_m from public.answer_options where question_id = v_p2 and position = 2;
  select id into v_n from public.answer_options where question_id = v_p2 and position = 3;

  assert (select cardinality(image_paths) from public.questions where id = v_q1) = 6, '6 Bilder gespeichert';
  assert (select kind from public.questions where id = v_p1) = 'poll', 'Art poll gespeichert';
  assert (select count(*) from public.answer_options where question_id in (v_p1, v_p2) and points <> 0) = 0,
    'Umfrage-Antworten haben immer 0 Punkte';

  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;
  perform public.join_game(v_code, 'P1', c_t1);
  perform public.join_game(v_code, 'P2', c_t2);
  perform public.join_game(v_code, 'P3', c_t3);
  assert (public.host_get_state(v_session)->>'question_total')::int = 2, 'gezählt werden nur gewertete Fragen';

  -- 1) normale Frage: unverändert
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert r#>>'{question,kind}' = 'question', 'Art der Frage';
  assert jsonb_array_length(public.host_get_state(v_session)#>'{question,images}') = 6, 'Host sieht 6 Bilder';
  update public.session_questions set last_opened_at = clock_timestamp() - interval '10 seconds'
  where session_id = v_session and question_id = v_q1;
  assert (public.submit_answer(c_t1, v_q1, array[v_q1a], 1)->>'ok')::boolean, 'P1 beantwortet Frage eins';
  assert (select points_awarded from public.player_answers where question_id = v_q1) = 5, 'Punkte wie bisher';
  assert (select answer_ms from public.player_answers where question_id = v_q1) between 10000 and 10500, 'Zeit wie bisher';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert r#>>'{results,0,tier}' = 'best' and r#>>'{results,1,tier}' = 'bad', 'Farbstufen bei Fragen unverändert: ' || (r->'results')::text;
  assert (r->>'my_question_score')::int = 5, 'eigene Punkte bei Fragen unverändert';
  assert (r->>'answered_count')::int = 1, 'eine Person hat geantwortet';

  -- Stand vor den Umfragen merken
  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_before
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;

  -- 2) Umfrage mit einer Antwort
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'QUESTION_OPEN', 'Umfrage wird wie eine Frage geöffnet: ' || r::text;
  v_ver := (r->>'version')::int;
  assert (select count(*) from public.session_questions where session_id = v_session) = 1, 'Umfrage erzeugt keinen Zeiteintrag';

  r := public.get_state(c_t1);
  assert r#>>'{question,kind}' = 'poll', 'Spieler:in sieht die Art Umfrage';
  assert (r#>>'{question,number}')::int = 1 and (r#>>'{question,total}')::int = 2, 'Umfrage zählt nicht als Frage: ' || (r->'question')::text;
  assert r::text not like '%points%' and r::text not like '%tier%' and r::text not like '%top%', 'offene Umfrage ohne Hinweise';

  assert (public.submit_answer(c_t1, v_p1, array[v_x], 1)->>'ok')::boolean, 'P1 stimmt ab';
  assert (public.submit_answer(c_t2, v_p1, array[v_x], 1)->>'ok')::boolean, 'P2 stimmt ab';
  assert (public.submit_answer(c_t3, v_p1, array[v_y], 1)->>'ok')::boolean, 'P3 stimmt ab';
  assert public.submit_answer(c_t3, v_p1, array[v_x, v_y], 2)->>'error' = 'INVALID_SELECTION', 'nur eine Antwort erlaubt';

  -- Manipulationsversuch: selbst wenn in der Datenbank Punkte stünden und es einen
  -- Zeiteintrag gäbe, entstehen für eine Umfrage weder Punkte noch Zeit.
  update public.answer_options set points = 50 where id = v_x;
  insert into public.session_questions (session_id, question_id, open_ms, last_opened_at)
  values (v_session, v_p1, 0, clock_timestamp() - interval '30 seconds');
  assert (public.submit_answer(c_t1, v_p1, array[v_x], 2)->>'ok')::boolean, 'P1 sendet erneut';
  assert (select count(*) from public.player_answers
          where question_id = v_p1 and (points_awarded <> 0 or answer_ms <> 0)) = 0,
    'Umfrage-Antworten haben nie Punkte oder Zeit';

  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_after
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;
  assert v_after = v_before, 'Umfrage verändert weder Score noch Zeit noch Rang: ' || v_before::text || ' / ' || v_after::text;

  delete from public.session_questions where session_id = v_session and question_id = v_p1;
  update public.answer_options set points = 0 where id = v_x;

  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  assert public.submit_answer(c_t3, v_p1, array[v_z], 9)->>'error' = 'QUESTION_NOT_OPEN', 'geschlossene Umfrage nimmt nichts mehr an';
  r := public.get_state(c_t1);
  assert r::text not like '%top%', 'geschlossene Umfrage zeigt noch kein Ergebnis';

  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t3);
  assert (r#>>'{results,0,count}')::int = 2 and (r#>>'{results,1,count}')::int = 1 and (r#>>'{results,2,count}')::int = 0,
    'Stimmen X=2, Y=1, Z=0: ' || (r->'results')::text;
  assert (r#>>'{results,0,top}')::boolean and not (r#>>'{results,1,top}')::boolean and not (r#>>'{results,2,top}')::boolean,
    'X ist die Mehrheit: ' || (r->'results')::text;
  assert (r->>'answered_count')::int = 3, 'drei Personen haben abgestimmt';
  assert r::text not like '%tier%' and r::text not like '%points%', 'Umfrage ohne Farbstufen und Punkte';
  assert r->'my_question_score' = 'null'::jsonb, 'keine eigenen Punkte bei einer Umfrage';

  r := public.host_get_state(v_session);
  assert r#>>'{question,kind}' = 'poll' and (r->>'answered_count')::int = 3, 'Host: Umfrage mit 3 Antworten';
  assert (r#>>'{question,options,0,count}')::int = 2, 'Host: aggregierte Stimmen';
  assert r::text not like '%option_ids%', 'Host-Daten enthalten keine einzelnen Antworten';

  -- 3) Umfrage mit mehreren Antworten: Anteile dürfen zusammen über 100 % liegen, Gleichstand
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  assert (public.submit_answer(c_t1, v_p2, array[v_l, v_m], 1)->>'ok')::boolean, 'P1 wählt L und M';
  assert (public.submit_answer(c_t2, v_p2, array[v_m, v_l], 1)->>'ok')::boolean, 'P2 wählt M und L';
  assert public.submit_answer(c_t3, v_p2, array[v_l, v_m, v_n], 1)->>'error' = 'INVALID_SELECTION', 'höchstens zwei Antworten';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t3);
  assert (r->>'answered_count')::int = 2, 'zwei Personen haben abgestimmt (Basis für Prozent)';
  assert (r#>>'{results,0,count}')::int = 2 and (r#>>'{results,1,count}')::int = 2 and (r#>>'{results,2,count}')::int = 0,
    'L=2, M=2, N=0 – zusammen mehr als die Zahl der Personen: ' || (r->'results')::text;
  assert (r#>>'{results,0,top}')::boolean and (r#>>'{results,1,top}')::boolean and not (r#>>'{results,2,top}')::boolean,
    'Gleichstand: L und M sind beide Mehrheit, N mit 0 Stimmen nicht: ' || (r->'results')::text;

  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_after
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;
  assert v_after = v_before, 'auch nach der zweiten Umfrage ist die Wertung unverändert';
  assert (select count(*) from public.session_questions where session_id = v_session) = 1, 'weiterhin nur ein Zeiteintrag';

  -- 4) zweite Frage: Wertung läuft normal weiter
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t2);
  assert (r#>>'{question,number}')::int = 2 and (r#>>'{question,total}')::int = 2, 'Frage 2 von 2';
  update public.session_questions set last_opened_at = clock_timestamp() - interval '4 seconds'
  where session_id = v_session and question_id = v_q2;
  assert (public.submit_answer(c_t2, v_q2, array[v_q2a], 1)->>'ok')::boolean, 'P2 beantwortet Frage zwei';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;

  -- Zeiten nur aus den zwei Fragen: P1 10 s + 4 s, P2 10 s + 4 s, P3 10 s + 4 s
  r := public.host_get_state(v_session);
  assert r#>>'{players,0,name}' = 'P1' and (r#>>'{players,0,score}')::int = 5, 'P1 führt mit 5 Punkten: ' || (r->'players')::text;
  assert r#>>'{players,1,name}' = 'P2' and (r#>>'{players,1,score}')::int = 3, 'P2 hat 3 Punkte';
  assert r#>>'{players,2,name}' = 'P3' and (r#>>'{players,2,score}')::int = 0, 'P3 hat 0 Punkte';
  assert (r#>>'{players,0,time_ms}')::bigint between 14000 and 15000
     and (r#>>'{players,2,time_ms}')::bigint between 14000 and 15000, 'Zeiten ohne Umfragen: ' || (r->'players')::text;
  assert (select count(*) from public.session_questions where session_id = v_session) = 2, 'zwei Zeiteinträge für zwei Fragen';

  r := public.host_action(v_session, v_ver, 'END');
  assert (public.host_delete_session(v_session)->>'ok')::boolean, 'Session löschen';
  assert (public.host_delete_quiz(v_quiz)->>'ok')::boolean, 'Quiz löschen';

  -- ein Quiz nur aus Umfragen lässt sich spielen
  r := public.host_save_quiz('{"title":"__polls_only__","items":[{"kind":"poll","text":"p","max_selections":1,"options":[{"label":"a"},{"label":"b"}]}]}');
  assert (r->>'ok')::boolean, 'Quiz nur aus Umfragen speichern: ' || r::text;
  v_quiz := (r->>'quiz_id')::uuid;
  r := public.host_create_session(v_quiz);
  assert (r->>'ok')::boolean, 'Quiz nur aus Umfragen starten: ' || r::text;
  assert (public.host_delete_session((r->>'session_id')::uuid)->>'ok')::boolean, 'Session löschen';
  assert (public.host_delete_quiz(v_quiz)->>'ok')::boolean, 'Quiz löschen';
end;
$$;

select 'Umfragen Selbsttest: alle Checks bestanden' as ergebnis;
