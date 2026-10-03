-- töricht live – Selbsttest für den eingeplanten Zwischenstand
-- Im Supabase SQL Editor ausführen (nach 011_planned_leaderboard.sql).
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder. Schlägt ein Check
-- fehl, bricht das Skript ab und hinterlässt nichts.

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_q1 uuid; v_l1 uuid; v_q2 uuid; v_l2 uuid;
  v_q1a uuid; v_q2a uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  v_before jsonb;
  v_after jsonb;
  r jsonb;
  c_t1 constant text := 'board-token-1-aaaaaaaaaaaaaaaaaaaaaaaaaaa';
  c_t2 constant text := 'board-token-2-bbbbbbbbbbbbbbbbbbbbbbbbbbb';
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  -- Validierung
  assert public.host_save_quiz('{"title":"x","items":[{"kind":"leaderboard","options":[{"label":"a","points":1},{"label":"b","points":0}]}]}')->>'error' = 'INVALID_LEADERBOARD', 'Zwischenstand mit Antworten';
  assert (select count(*) from public.quizzes where title = 'x') = 0, 'ungültiges Quiz legt nichts an';

  -- ein Quiz nur aus Zwischenständen lässt sich speichern, aber nicht spielen
  r := public.host_save_quiz('{"title":"__board_only__","items":[{"kind":"leaderboard"}]}');
  assert (r->>'ok')::boolean, 'Quiz nur aus Zwischenstand speichern: ' || r::text;
  assert public.host_create_session((r->>'quiz_id')::uuid)->>'error' = 'QUIZ_EMPTY', 'Quiz ohne Frage startet nicht';
  assert (public.host_delete_quiz((r->>'quiz_id')::uuid)->>'ok')::boolean, 'Quiz löschen';

  -- Frage → Zwischenstand → Frage → Zwischenstand
  r := public.host_save_quiz(jsonb_build_object(
    'title', '__board_selftest__',
    'items', jsonb_build_array(
      jsonb_build_object('kind', 'question', 'text', 'Frage eins', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 5), jsonb_build_object('label', 'B', 'points', 0))),
      -- Text und Medien bei einem Zwischenstand werden verworfen
      jsonb_build_object('kind', 'leaderboard', 'text', 'wird verworfen'),
      jsonb_build_object('kind', 'question', 'text', 'Frage zwei', 'max_selections', 1,
        'options', jsonb_build_array(
          jsonb_build_object('label', 'A', 'points', 3), jsonb_build_object('label', 'B', 'points', 0))),
      jsonb_build_object('kind', 'leaderboard'))));
  assert (r->>'ok')::boolean, 'Quiz mit Zwischenständen speichern: ' || r::text;
  v_quiz := (r->>'quiz_id')::uuid;

  select id into v_q1 from public.questions where quiz_id = v_quiz and position = 1;
  select id into v_l1 from public.questions where quiz_id = v_quiz and position = 2;
  select id into v_q2 from public.questions where quiz_id = v_quiz and position = 3;
  select id into v_l2 from public.questions where quiz_id = v_quiz and position = 4;
  select id into v_q1a from public.answer_options where question_id = v_q1 and position = 1;
  select id into v_q2a from public.answer_options where question_id = v_q2 and position = 1;
  assert (select kind = 'leaderboard' and text = '' from public.questions where id = v_l1), 'Zwischenstand ohne Text gespeichert';
  assert (select count(*) from public.answer_options where question_id in (v_l1, v_l2)) = 0, 'Zwischenstand ohne Antworten';

  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;
  perform public.join_game(v_code, 'B1', c_t1);
  perform public.join_game(v_code, 'B2', c_t2);
  assert (public.host_get_state(v_session)->>'question_total')::int = 2, 'gezählt werden nur Fragen';

  -- Frage eins
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  update public.session_questions set last_opened_at = clock_timestamp() - interval '10 seconds'
  where session_id = v_session and question_id = v_q1;
  assert (public.submit_answer(c_t1, v_q1, array[v_q1a], 1)->>'ok')::boolean, 'B1 antwortet';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  assert public.host_get_state(v_session)#>>'{next,kind}' = 'leaderboard', 'als Nächstes kommt der Zwischenstand';

  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_before
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;

  -- "weiter" führt zum eingeplanten Zwischenstand
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'LEADERBOARD', 'eingeplanter Zwischenstand: ' || r::text;
  assert (r->>'current_question_id')::uuid = v_l1, 'aktueller Eintrag ist der Zwischenstand';
  v_ver := (r->>'version')::int;

  r := public.host_get_state(v_session);
  assert r->>'current_kind' = 'leaderboard', 'Host: Art des aktuellen Eintrags';
  assert not (r ? 'question') and not (r ? 'slide'), 'Host: keine Frage, keine Slide';
  assert r#>>'{next,kind}' = 'question', 'danach kommt wieder eine Frage';

  r := public.get_state(c_t2);
  assert r#>>'{session,state}' = 'LEADERBOARD' and jsonb_array_length(r->'leaderboard') = 2, 'Spieler:in sieht die Rangliste';
  assert not (r ? 'question'), 'keine Frage beim Zwischenstand';
  r := public.presenter_get_state(v_session);
  assert r#>>'{leaderboard,0,name}' = 'B1' and (r#>>'{leaderboard,0,score}')::int = 5, 'Presenter zeigt die Rangliste';

  assert public.submit_answer(c_t2, v_l1, array[v_q1a], 1)->>'error' = 'QUESTION_NOT_OPEN', 'Zwischenstand nimmt keine Antworten an';
  assert public.host_action(v_session, v_ver, 'SHOW_RESULTS')->>'error' = 'INVALID_TRANSITION', 'eingeplanter Zwischenstand lässt sich nicht verstecken';
  assert (select count(*) from public.session_questions where session_id = v_session) = 1, 'Zwischenstand erzeugt keinen Zeiteintrag';

  perform pg_sleep(1);
  select jsonb_agg(jsonb_build_array(p->'name', p->'score', p->'time_ms', p->'rank') order by p->>'name') into v_after
  from jsonb_array_elements(public.host_get_state(v_session)->'players') p;
  assert v_after = v_before, 'Zwischenstand verändert weder Punkte noch Zeit: ' || v_before::text || ' / ' || v_after::text;

  -- Frage zwei: Zählung ohne Zwischenstand
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'QUESTION_OPEN', 'Frage zwei: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t2);
  assert (r#>>'{question,number}')::int = 2 and (r#>>'{question,total}')::int = 2, 'Frage 2 von 2';
  assert (public.submit_answer(c_t2, v_q2, array[v_q2a], 1)->>'ok')::boolean, 'B2 antwortet';
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;

  -- zweiter Zwischenstand direkt nach dem Schließen, danach nichts mehr
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert r->>'state' = 'LEADERBOARD', 'zweiter Zwischenstand: ' || r::text;
  v_ver := (r->>'version')::int;
  assert public.host_get_state(v_session)->'next' = 'null'::jsonb, 'danach kommt nichts mehr';
  assert public.host_action(v_session, v_ver, 'OPEN_NEXT')->>'error' = 'NO_MORE_QUESTIONS', 'kein weiterer Eintrag';
  r := public.host_action(v_session, v_ver, 'SHOW_FINAL');
  assert r->>'state' = 'FINAL_RESULTS', 'Finale aus dem Zwischenstand: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert (r#>>'{me,score}')::int = 5 and (r#>>'{me,rank}')::int = 1, 'B1 gewinnt mit 5 Punkten';
  r := public.host_action(v_session, v_ver, 'END');

  assert (public.host_delete_session(v_session)->>'ok')::boolean, 'Session löschen';
  assert (public.host_delete_quiz(v_quiz)->>'ok')::boolean, 'Quiz löschen';
end;
$$;

select 'Zwischenstand Selbsttest: alle Checks bestanden' as ergebnis;
