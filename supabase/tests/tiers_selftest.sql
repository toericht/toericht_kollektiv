-- töricht live – Selbsttest für die farbliche Auflösung (grün / gelb / rot)
-- Im Supabase SQL Editor ausführen (nach 006_result_tiers.sql).
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder.

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_q1 uuid; v_q2 uuid;
  v_a uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  r jsonb;
  c_t constant text := 'tiers-token-1-aaaaaaaaaaaaaaaaaaaaaaaaaaa';
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  insert into public.quizzes (title) values ('__tiers_selftest__') returning id into v_quiz;
  -- Frage 1: zweimal das Maximum, einmal positiv darunter, null, negativ
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 1, 'F1', 1) returning id into v_q1;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 1, 'A', 10) returning id into v_a;
  insert into public.answer_options (question_id, position, label, points) values
    (v_q1, 2, 'B', 3), (v_q1, 3, 'C', 10), (v_q1, 4, 'D', 0), (v_q1, 5, 'E', -2);
  -- Frage 2: keine positive Punktzahl
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 2, 'F2', 1) returning id into v_q2;
  insert into public.answer_options (question_id, position, label, points) values
    (v_q2, 1, 'A', 0), (v_q2, 2, 'B', -5);

  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;
  perform public.join_game(v_code, 'T', c_t);

  -- offen und geschlossen: kein Hinweis auf Punkte oder Stufen
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t);
  assert r::text not like '%tier%' and r::text not like '%points%', 'offene Frage ohne Stufen und Punkte: ' || r::text;
  perform public.submit_answer(c_t, v_q1, array[v_a], 1);

  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t);
  assert r::text not like '%tier%' and r::text not like '%points%', 'geschlossene Frage ohne Stufen und Punkte: ' || r::text;
  assert not (r ? 'my_question_score'), 'eigene Punkte erst in der Auflösung';

  -- Ergebnisse: Stufen ja, Punktwerte nein
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t);
  assert r#>>'{results,0,tier}' = 'best', 'A (10) ist best: ' || (r->'results')::text;
  assert r#>>'{results,1,tier}' = 'good', 'B (3) ist good: ' || (r->'results')::text;
  assert r#>>'{results,2,tier}' = 'best', 'C (10) ist ebenfalls best: ' || (r->'results')::text;
  assert r#>>'{results,3,tier}' = 'bad', 'D (0) ist bad: ' || (r->'results')::text;
  assert r#>>'{results,4,tier}' = 'bad', 'E (-2) ist bad: ' || (r->'results')::text;
  assert (r#>>'{results,0,count}')::int = 1, 'Zählung unverändert';
  assert (r->>'my_question_score')::int = 10, 'eigene Punkte für die Frage: ' || r::text;
  assert r::text not like '%points%', 'Ergebnisse weiterhin ohne Punktwerte';
  assert (select points_awarded from public.player_answers where question_id = v_q1) = 10, 'Punktevergabe unverändert';

  -- keine positive Punktzahl: alles bad
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t);
  assert r#>>'{results,0,tier}' = 'bad' and r#>>'{results,1,tier}' = 'bad', 'ohne positive Punkte ist alles bad: ' || (r->'results')::text;
  assert r->'my_question_score' = 'null'::jsonb, 'ohne Antwort keine eigenen Punkte: ' || r::text;

  -- Leaderboard enthält keine Stufen
  r := public.host_action(v_session, v_ver, 'SHOW_LEADERBOARD');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t);
  assert r::text not like '%tier%', 'Leaderboard ohne Stufen';

  r := public.host_action(v_session, v_ver, 'END');
  delete from public.game_sessions where id = v_session;
  delete from public.quizzes where id = v_quiz;
end;
$$;

select 'Farbstufen Selbsttest: alle Checks bestanden' as ergebnis;
