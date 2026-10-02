-- töricht live – Selbsttest für Phase 2
-- Im Supabase SQL Editor ausführen (nach 001–003).
-- Legt ein eigenes Quiz an, spielt ein Spiel durch und löscht am Ende alles wieder.
-- Schlägt ein Check fehl, bricht das Skript mit einer Fehlermeldung ab und
-- hinterlässt nichts. Erfolg = letzte Zeile "alle Checks bestanden".

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_q1 uuid; v_q1a uuid; v_q1b uuid; v_q1c uuid; v_q1d uuid;
  v_q2 uuid; v_q2a uuid; v_q2b uuid; v_q2c uuid;
  v_session uuid;
  v_code text;
  v_ver int;
  v_p1 uuid; v_p2 uuid;
  v_rcode text;
  r jsonb;
  c_t1  constant text := 'selftest-token-1-aaaaaaaaaaaaaaaaaaaaaaaa';
  c_t2  constant text := 'selftest-token-2-bbbbbbbbbbbbbbbbbbbbbbbb';
  c_t1n constant text := 'selftest-token-1-new-cccccccccccccccccccc';
  c_t3  constant text := 'selftest-token-3-dddddddddddddddddddddddd';
begin
  -- als Host ausgeben (gilt nur innerhalb dieser Transaktion)
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts – zuerst 003_host_allowlist.sql ausführen';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);
  assert public.is_host(), 'is_host() sollte true sein';

  -- Rechte
  assert not has_table_privilege('anon', 'public.answer_options', 'select'), 'anon darf answer_options nicht lesen';
  assert not has_table_privilege('anon', 'public.questions', 'select'), 'anon darf questions nicht lesen';
  assert not has_table_privilege('anon', 'public.players', 'select'), 'anon darf players nicht lesen';
  assert not has_table_privilege('anon', 'public.player_answers', 'insert'), 'anon darf player_answers nicht schreiben';
  assert not has_table_privilege('authenticated', 'public.player_answers', 'select'), 'authenticated darf player_answers nicht direkt lesen';
  assert not has_function_privilege('anon', 'public.host_action(uuid, int, text)', 'execute'), 'anon darf host_action nicht ausführen';
  assert not has_function_privilege('anon', 'public.host_get_state(uuid)', 'execute'), 'anon darf host_get_state nicht ausführen';
  assert has_function_privilege('anon', 'public.submit_answer(text, uuid, uuid[], bigint)', 'execute'), 'anon muss submit_answer ausführen dürfen';

  -- Quiz
  insert into public.quizzes (title) values ('__selftest__') returning id into v_quiz;
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 1, 'S1', 1) returning id into v_q1;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 1, 'A', 0) returning id into v_q1a;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 2, 'B', 2) returning id into v_q1b;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 3, 'C', 5) returning id into v_q1c;
  insert into public.answer_options (question_id, position, label, points) values (v_q1, 4, 'D', -3) returning id into v_q1d;
  insert into public.questions (quiz_id, position, text, max_selections) values (v_quiz, 2, 'S2', 2) returning id into v_q2;
  insert into public.answer_options (question_id, position, label, points) values (v_q2, 1, 'A', 1) returning id into v_q2a;
  insert into public.answer_options (question_id, position, label, points) values (v_q2, 2, 'B', 4) returning id into v_q2b;
  insert into public.answer_options (question_id, position, label, points) values (v_q2, 3, 'C', -2) returning id into v_q2c;

  -- Session
  r := public.host_create_session(v_quiz);
  assert (r->>'ok')::boolean, 'host_create_session: ' || r::text;
  v_session := (r->>'session_id')::uuid;
  v_code := r->>'join_code';
  v_ver := (r->>'version')::int;
  assert char_length(v_code) = 5, 'Join-Code sollte 5 Zeichen haben';

  -- Beitritt: gleicher Nickname erlaubt, wiederholter Request idempotent
  r := public.join_game(lower(v_code), '  Vieh ', c_t1);
  assert (r->>'ok')::boolean, 'join p1: ' || r::text;
  v_p1 := (r->>'player_id')::uuid;
  assert r->>'nickname' = 'Vieh', 'Nickname sollte getrimmt sein';
  r := public.join_game(v_code, 'Vieh', c_t2);
  assert (r->>'ok')::boolean, 'join p2: ' || r::text;
  v_p2 := (r->>'player_id')::uuid;
  assert v_p1 <> v_p2, 'gleicher Nickname muss zwei Personen ergeben';
  -- innerhalb einer Transaktion ist now() konstant; Beitrittsreihenfolge für den Test festlegen
  update public.players set joined_at = joined_at + interval '1 second' where id = v_p2;
  r := public.join_game(v_code, 'Vieh', c_t1);
  assert (r->>'player_id')::uuid = v_p1, 'wiederholter Join muss dieselbe Person liefern';
  assert (select count(*) from public.players where session_id = v_session) = 2, 'es darf nur 2 Personen geben';
  assert public.join_game(v_code, '', c_t3)->>'error' = 'INVALID_NICKNAME', 'leerer Nickname';
  assert public.join_game(v_code, 'x', 'kurz')->>'error' = 'INVALID_TOKEN', 'zu kurzes Token';
  assert public.join_game('ZZZZZZZZ', 'x', c_t3)->>'error' = 'SESSION_NOT_FOUND', 'unbekannter Code';

  -- Lobby: keine Frage sichtbar, Antworten abgelehnt
  r := public.get_state(c_t1);
  assert r#>>'{session,state}' = 'LOBBY', 'Zustand LOBBY';
  assert not (r ? 'question'), 'in der Lobby darf keine Frage sichtbar sein';
  assert public.submit_answer(c_t1, v_q1, array[v_q1c], 1)->>'error' = 'QUESTION_NOT_OPEN', 'Antwort in der Lobby';
  assert public.get_state('unbekanntes-token-xxxxxxxxxxxxxxxxxxxxxxxx')->>'error' = 'UNKNOWN_PLAYER', 'unbekanntes Token';

  -- Frage 1 öffnen; doppelter Klick mit alter Version wird abgelehnt
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  assert (r->>'ok')::boolean, 'OPEN_NEXT: ' || r::text;
  assert public.host_action(v_session, v_ver, 'OPEN_NEXT')->>'error' = 'VERSION_MISMATCH', 'alte Version muss abgelehnt werden';
  v_ver := (r->>'version')::int;
  assert (r->>'current_question_id')::uuid = v_q1, 'erste Frage';

  r := public.get_state(c_t1);
  assert r#>>'{question,id}' = v_q1::text, 'aktuelle Frage sichtbar';
  assert jsonb_array_length(r#>'{question,options}') = 4, '4 Optionen';
  assert r::text not like '%points%', 'get_state darf keine Punktwerte enthalten';
  assert not (r ? 'leaderboard') and not (r ? 'me'), 'kein Score während offener Frage';
  assert r->'my_answer' = 'null'::jsonb, 'noch keine Antwort';

  -- Antworten: speichern, wiederholen, ändern, veralteter Request
  r := public.submit_answer(c_t1, v_q1, array[v_q1c], 1);
  assert (r->>'ok')::boolean, 'submit C: ' || r::text;
  r := public.submit_answer(c_t1, v_q1, array[v_q1c], 1);
  assert (r->>'ok')::boolean, 'wiederholter submit';
  assert (select count(*) from public.player_answers where player_id = v_p1) = 1, 'genau eine Antwortzeile';
  assert (select points_awarded from public.player_answers where player_id = v_p1) = 5, 'C = 5 Punkte';
  r := public.submit_answer(c_t1, v_q1, array[v_q1b], 2);
  assert (select points_awarded from public.player_answers where player_id = v_p1) = 2, 'Änderung auf B = 2 Punkte';
  r := public.submit_answer(c_t1, v_q1, array[v_q1d], 1);
  assert (r->>'client_seq')::bigint = 2, 'veralteter Request darf nicht überschreiben';
  assert (select points_awarded from public.player_answers where player_id = v_p1) = 2, 'weiterhin 2 Punkte';
  assert (select count(*) from public.player_answers where player_id = v_p1) = 1, 'weiterhin eine Zeile';

  -- ungültige Auswahl
  assert public.submit_answer(c_t1, v_q1, array[v_q1a, v_q1b], 3)->>'error' = 'INVALID_SELECTION', 'zu viele Optionen';
  assert public.submit_answer(c_t1, v_q1, array[v_q2a], 3)->>'error' = 'INVALID_SELECTION', 'Option einer anderen Frage';
  assert public.submit_answer(c_t1, v_q1, array[]::uuid[], 3)->>'error' = 'INVALID_SELECTION', 'leere Auswahl';
  assert public.submit_answer(c_t1, v_q2, array[v_q2a], 3)->>'error' = 'QUESTION_NOT_OPEN', 'zukünftige Frage';

  r := public.submit_answer(c_t2, v_q1, array[v_q1d], 1);
  assert (r->>'ok')::boolean, 'submit p2';

  -- Schließen: danach keine Änderung mehr
  r := public.host_action(v_session, v_ver, 'CLOSE');
  assert (r->>'ok')::boolean, 'CLOSE: ' || r::text;
  v_ver := (r->>'version')::int;
  assert public.submit_answer(c_t1, v_q1, array[v_q1c], 9)->>'error' = 'QUESTION_NOT_OPEN', 'Antwort nach dem Schließen';
  assert (select points_awarded from public.player_answers where player_id = v_p1) = 2, 'Punkte nach dem Schließen unverändert';
  assert public.host_action(v_session, v_ver, 'CLOSE')->>'error' = 'INVALID_TRANSITION', 'CLOSE aus QUESTION_CLOSED';

  -- Ergebnisse: Verteilung ja, Punkte nein
  r := public.host_action(v_session, v_ver, 'SHOW_RESULTS');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert jsonb_array_length(r->'results') = 4, 'Ergebnisverteilung';
  assert r::text not like '%points%', 'Ergebnisse ohne Punktwerte';
  assert not (r ? 'leaderboard'), 'kein Leaderboard in RESULTS';

  -- Leaderboard: doppelte Namen unterscheidbar, Scores korrekt
  r := public.host_action(v_session, v_ver, 'SHOW_LEADERBOARD');
  v_ver := (r->>'version')::int;
  r := public.get_state(c_t1);
  assert (r#>>'{me,score}')::int = 2, 'Score p1 = 2';
  assert (r#>>'{me,rank}')::int = 1, 'Rang p1 = 1';
  assert r#>>'{me,name}' = 'Vieh', 'Anzeigename p1';
  r := public.get_state(c_t2);
  assert (r#>>'{me,score}')::int = -3, 'Score p2 = -3';
  assert r#>>'{me,name}' = 'Vieh (2)', 'Anzeigename p2';
  assert jsonb_array_length(r->'leaderboard') = 2, 'Leaderboard mit 2 Einträgen';

  -- Host-Sicht enthält Punktwerte und Zähler
  r := public.host_get_state(v_session);
  assert (r->>'ok')::boolean, 'host_get_state: ' || r::text;
  assert (r->>'player_count')::int = 2 and (r->>'answered_count')::int = 2, 'Zähler in Host-Sicht';
  assert r#>>'{question,options,2,points}' = '5', 'Host sieht Punktwerte';

  -- Frage 2 (Multiple Choice)
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  assert (r->>'current_question_id')::uuid = v_q2, 'zweite Frage';
  r := public.submit_answer(c_t2, v_q2, array[v_q2b, v_q2c, v_q2b], 1);
  assert (r->>'ok')::boolean, 'Mehrfachauswahl (Duplikate werden entfernt): ' || r::text;
  assert (select points_awarded from public.player_answers where player_id = v_p2 and question_id = v_q2) = 2, 'B + C = 2 Punkte';
  assert public.submit_answer(c_t2, v_q2, array[v_q2a, v_q2b, v_q2c], 2)->>'error' = 'INVALID_SELECTION', 'mehr als max_selections';

  -- Recovery
  r := public.host_create_recovery_code(v_p1);
  assert (r->>'ok')::boolean, 'Recovery-Code erzeugen: ' || r::text;
  v_rcode := r->>'code';
  assert char_length(v_rcode) = 6, 'Recovery-Code hat 6 Zeichen';
  assert (select count(*) from public.recovery_codes where code_hash = v_rcode) = 0, 'Code darf nicht im Klartext gespeichert sein';
  assert public.recover_player(v_code, 'AAAAAA', c_t1n)->>'error' = 'INVALID_CODE', 'falscher Code';
  r := public.recover_player(v_code, lower(v_rcode), c_t1n);
  assert (r->>'ok')::boolean and (r->>'player_id')::uuid = v_p1, 'Recovery: ' || r::text;
  assert public.get_state(c_t1)->>'error' = 'UNKNOWN_PLAYER', 'altes Token muss ungültig sein';
  assert (public.get_state(c_t1n)->>'ok')::boolean, 'neues Token gültig';
  assert (public.recover_player(v_code, v_rcode, c_t1n)->>'ok')::boolean, 'Wiederholung desselben Recovery-Requests';
  assert public.recover_player(v_code, v_rcode, c_t3)->>'error' = 'INVALID_CODE', 'Code ist nur einmal gültig';

  -- abgelaufener Code
  r := public.host_create_recovery_code(v_p2);
  v_rcode := r->>'code';
  update public.recovery_codes set expires_at = now() - interval '1 second' where player_id = v_p2 and used_at is null;
  assert public.recover_player(v_code, v_rcode, c_t3)->>'error' = 'INVALID_CODE', 'abgelaufener Code';

  -- nach 10 Fehlversuchen verfallen aktive Codes
  r := public.host_create_recovery_code(v_p2);
  v_rcode := r->>'code';
  for i in 1..10 loop
    perform public.recover_player(v_code, 'BBBBBB', c_t3);
  end loop;
  assert public.recover_player(v_code, v_rcode, c_t3)->>'error' = 'INVALID_CODE', 'Code nach 10 Fehlversuchen ungültig';

  -- Person entfernen
  assert (public.host_set_player_removed(v_p2, true)->>'ok')::boolean, 'Person entfernen';
  assert public.get_state(c_t2)->>'error' = 'REMOVED', 'entfernte Person';
  assert public.submit_answer(c_t2, v_q2, array[v_q2a], 5)->>'error' = 'REMOVED', 'entfernte Person darf nicht antworten';

  -- Ende
  r := public.host_action(v_session, v_ver, 'CLOSE');
  v_ver := (r->>'version')::int;
  assert public.host_action(v_session, v_ver, 'OPEN_NEXT')->>'error' = 'NO_MORE_QUESTIONS', 'keine weitere Frage';
  r := public.host_action(v_session, v_ver, 'SHOW_FINAL');
  assert r->>'state' = 'FINAL_RESULTS', 'FINAL_RESULTS: ' || r::text;
  v_ver := (r->>'version')::int;
  r := public.host_action(v_session, v_ver, 'END');
  assert r->>'state' = 'ENDED', 'ENDED: ' || r::text;
  assert public.join_game(v_code, 'spät', c_t3)->>'error' = 'SESSION_ENDED', 'Beitritt nach Ende';
  r := public.get_state(c_t1n);
  assert (r#>>'{me,score}')::int = 2, 'Score bleibt nach Ende erhalten';

  -- ohne Host-Login keine Host-Funktionen
  perform set_config('request.jwt.claims', '{}', true);
  assert public.host_get_state(v_session)->>'error' = 'NOT_HOST', 'host_get_state ohne Login';
  assert public.host_action(v_session, v_ver, 'END')->>'error' = 'NOT_HOST', 'host_action ohne Login';

  -- aufräumen
  delete from public.game_sessions where id = v_session;
  delete from public.quizzes where id = v_quiz;
end;
$$;

select 'Phase 2 Selbsttest: alle Checks bestanden' as ergebnis;
