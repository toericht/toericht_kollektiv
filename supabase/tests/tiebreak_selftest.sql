-- töricht live – Selbsttest für den Zeit-Tie-Breaker
-- Im Supabase SQL Editor ausführen (nach 004_tiebreak_time.sql). Dauert ca. 2 Sekunden.
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder. Schlägt ein Check
-- fehl, bricht das Skript ab und hinterlässt nichts.
--
-- Der Test "spult" die Zeit vor, indem er den Öffnungszeitpunkt der Frage in
-- die Vergangenheit verschiebt. Über die API ist das nicht möglich.

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_q1 uuid; v_q1a uuid; v_q1b uuid;
  v_q2 uuid; v_q2a uuid;
  v_q3 uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid;
  v_ms bigint;
  r jsonb;
  c_t1 constant text := 'tiebreak-token-1-aaaaaaaaaaaaaaaaaaaaaaaa';
  c_t2 constant text := 'tiebreak-token-2-bbbbbbbbbbbbbbbbbbbbbbbb';
  c_t3 constant text := 'tiebreak-token-3-cccccccccccccccccccccccc';
  c_t4 constant text := 'tiebreak-token-4-dddddddddddddddddddddddd';
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  assert not has_table_privilege('anon', 'public.session_questions', 'select'), 'anon darf session_questions nicht lesen';
  assert not has_table_privilege('authenticated', 'public.session_questions', 'update'), 'authenticated darf session_questions nicht ändern';

  -- Quiz: Frage 1 mit zwei gleich bewerteten Antworten, damit Gleichstände entstehen
  insert into public.quizzes (title) values ('__tiebreak_selftest__') returning id into v_quiz;
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 1, 'T1', 1) returning id into v_q1;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 1, 'A', 5) returning id into v_q1a;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 2, 'B', 5) returning id into v_q1b;
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 2, 'T2', 1) returning id into v_q2;
  insert into public.answer_options (question_id, position, label, points) values (v_q2, 1, 'A', 1) returning id into v_q2a;
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 3, 'T3', 1) returning id into v_q3;
  insert into public.answer_options (question_id, position, label, points) values (v_q3, 1, 'A', 1);

  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;

  v_p1 := (public.join_game(v_code, 'T1', c_t1)->>'player_id')::uuid;
  v_p2 := (public.join_game(v_code, 'T2', c_t2)->>'player_id')::uuid;
  v_p3 := (public.join_game(v_code, 'T3', c_t3)->>'player_id')::uuid;
  v_p4 := (public.join_game(v_code, 'T4', c_t4)->>'player_id')::uuid;

  -- Frage 1 öffnen: Zeitmessung startet
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  assert (select open_ms = 0 and last_opened_at is not null from public.session_questions
          where session_id = v_session and question_id = v_q1), 'Öffnungszeit von Frage 1 fehlt';

  -- p1 antwortet nach 10 s
  update public.session_questions set last_opened_at = clock_timestamp() - interval '10 seconds'
  where session_id = v_session and question_id = v_q1;
  perform public.submit_answer(c_t1, v_q1, array[v_q1a], 1);
  select answer_ms into v_ms from public.player_answers where player_id = v_p1;
  assert v_ms between 10000 and 10500, 'p1 sollte ~10 s haben, hat ' || v_ms;

  -- p2 antwortet nach 20 s
  update public.session_questions set last_opened_at = clock_timestamp() - interval '20 seconds'
  where session_id = v_session and question_id = v_q1;
  perform public.submit_answer(c_t2, v_q1, array[v_q1b], 1);
  select answer_ms into v_ms from public.player_answers where player_id = v_p2;
  assert v_ms between 20000 and 20500, 'p2 sollte ~20 s haben, hat ' || v_ms;

  -- p2 ändert nach 25 s: neue Abgabe ersetzt die Zeit
  update public.session_questions set last_opened_at = clock_timestamp() - interval '25 seconds'
  where session_id = v_session and question_id = v_q1;
  perform public.submit_answer(c_t2, v_q1, array[v_q1a], 2);
  select answer_ms into v_ms from public.player_answers where player_id = v_p2;
  assert v_ms between 25000 and 25500, 'geänderte Antwort sollte ~25 s haben, hat ' || v_ms;

  -- wiederholter und veralteter Request nach 28 s: Zeit bleibt unverändert
  update public.session_questions set last_opened_at = clock_timestamp() - interval '28 seconds'
  where session_id = v_session and question_id = v_q1;
  perform public.submit_answer(c_t2, v_q1, array[v_q1a], 2);
  perform public.submit_answer(c_t2, v_q1, array[v_q1b], 1);
  select answer_ms into v_ms from public.player_answers where player_id = v_p2;
  assert v_ms between 25000 and 25500, 'Wiederholung darf die Zeit nicht ändern, hat ' || v_ms;
  assert (select count(*) from public.player_answers where player_id = v_p2) = 1, 'genau eine Antwortzeile';

  -- nach 30 s schließen
  update public.session_questions set last_opened_at = clock_timestamp() - interval '30 seconds'
  where session_id = v_session and question_id = v_q1;
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  select open_ms into v_ms from public.session_questions where session_id = v_session and question_id = v_q1;
  assert v_ms between 30000 and 30500, 'Frage 1 sollte ~30 s offen gewesen sein, war ' || v_ms;
  assert (select last_opened_at is null from public.session_questions
          where session_id = v_session and question_id = v_q1), 'geschlossene Frage darf keine laufende Phase haben';

  -- 2 s Pause, dann REOPEN: Die Pause darf nicht zählen
  perform pg_sleep(2);
  r := public.host_action(v_session, v_ver, 'REOPEN');
  assert r->>'state' = 'QUESTION_OPEN', 'REOPEN: ' || r::text;
  v_ver := (r->>'version')::int;

  -- p3 antwortet 5 s nach dem Wiederöffnen: 30 s + 5 s, ohne die 2 s Pause
  update public.session_questions set last_opened_at = clock_timestamp() - interval '5 seconds'
  where session_id = v_session and question_id = v_q1;
  perform public.submit_answer(c_t3, v_q1, array[v_q1a], 1);
  select answer_ms into v_ms from public.player_answers where player_id = v_p3;
  assert v_ms between 35000 and 36500, 'p3 sollte ~35 s haben (Pause zählt nicht), hat ' || v_ms;

  -- REOPEN ändert keine bereits gespeicherten Zeiten
  select answer_ms into v_ms from public.player_answers where player_id = v_p1;
  assert v_ms between 10000 and 10500, 'p1 unverändert ~10 s, hat ' || v_ms;

  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;

  -- Ranking: gleiche Punkte, Zeit entscheidet. p4 hat nicht geantwortet.
  r := public.host_action(v_session, v_ver, 'SHOW_LEADERBOARD');
  v_ver := (r->>'version')::int;

  r := public.get_state(c_t1);
  assert (r#>>'{me,rank}')::int = 1 and (r#>>'{me,score}')::int = 5, 'p1 Platz 1: ' || (r->'me')::text;
  assert (r#>>'{me,tied}')::boolean, 'p1 teilt die Punktzahl';
  assert (r#>>'{me,time_ms}')::bigint between 10000 and 10500, 'p1 Zeit: ' || (r->'me')::text;
  assert r#>>'{leaderboard,0,name}' = 'T1' and r#>>'{leaderboard,1,name}' = 'T2'
     and r#>>'{leaderboard,2,name}' = 'T3' and r#>>'{leaderboard,3,name}' = 'T4', 'Reihenfolge: ' || (r->'leaderboard')::text;
  assert r::text not like '%points%', 'weiterhin keine Punktwerte';

  r := public.get_state(c_t2);
  assert (r#>>'{me,rank}')::int = 2, 'p2 Platz 2: ' || (r->'me')::text;
  r := public.get_state(c_t3);
  assert (r#>>'{me,rank}')::int = 3, 'p3 Platz 3: ' || (r->'me')::text;

  -- nicht geantwortet = volle Öffnungsdauer der Frage, kein Zeitvorteil
  r := public.get_state(c_t4);
  assert (r#>>'{me,rank}')::int = 4 and (r#>>'{me,score}')::int = 0, 'p4 Platz 4: ' || (r->'me')::text;
  assert not (r#>>'{me,tied}')::boolean, 'p4 teilt die Punktzahl nicht';
  assert (r#>>'{me,time_ms}')::bigint between 35000 and 36500, 'p4 Zeit = Öffnungsdauer: ' || (r->'me')::text;

  -- Punkte gehen vor Zeit: p3 ist am langsamsten, holt aber einen Punkt mehr
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  update public.session_questions set last_opened_at = clock_timestamp() - interval '50 seconds'
  where session_id = v_session and question_id = v_q2;
  perform public.submit_answer(c_t3, v_q2, array[v_q2a], 1);
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;

  r := public.host_get_state(v_session);
  assert r#>>'{players,0,name}' = 'T3' and (r#>>'{players,0,score}')::int = 6, 'p3 führt nach Punkten: ' || (r->'players')::text;
  assert r#>>'{players,1,name}' = 'T1' and r#>>'{players,2,name}' = 'T2', 'p1 vor p2 nach Zeit: ' || (r->'players')::text;
  assert (r#>>'{players,1,time_ms}')::bigint between 60000 and 61000, 'p1: 10 s + 50 s unbeantwortet: ' || (r->'players')::text;

  -- Spielende bei offener Frage schließt die laufende Zeitmessung ab
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  update public.session_questions set last_opened_at = clock_timestamp() - interval '3 seconds'
  where session_id = v_session and question_id = v_q3;
  r := public.host_action(v_session, v_ver, 'END');
  assert r->>'state' = 'ENDED', 'END: ' || r::text;
  select open_ms into v_ms from public.session_questions where session_id = v_session and question_id = v_q3;
  assert v_ms between 3000 and 3500, 'Frage 3 sollte ~3 s offen gewesen sein, war ' || v_ms;
  assert (select last_opened_at is null from public.session_questions
          where session_id = v_session and question_id = v_q3), 'nach END läuft keine Zeit mehr';

  -- aufräumen
  delete from public.game_sessions where id = v_session;
  delete from public.quizzes where id = v_quiz;
end;
$$;

select 'Tie-Breaker Selbsttest: alle Checks bestanden' as ergebnis;
