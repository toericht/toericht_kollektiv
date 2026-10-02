-- töricht live – Selbsttest für den Quiz-Editor
-- Im Supabase SQL Editor ausführen (nach 005_editor.sql).
-- Legt ein eigenes Quiz an und löscht am Ende alles wieder. Schlägt ein Check
-- fehl, bricht das Skript ab und hinterlässt nichts.

do $$
declare
  v_host uuid;
  v_quiz uuid;
  v_q1 uuid; v_q2 uuid;
  v_o1 uuid; v_o2 uuid; v_o3 uuid;
  v_session uuid;
  v_ver int;
  r jsonb;
begin
  select h.user_id into v_host from public.hosts h limit 1;
  assert v_host is not null, 'kein Host in public.hosts';

  -- Rechte
  assert not has_table_privilege('authenticated', 'public.answer_options', 'update'), 'Hosts schreiben nicht mehr direkt in answer_options';
  assert not has_table_privilege('authenticated', 'public.questions', 'delete'), 'Hosts löschen nicht mehr direkt in questions';
  assert has_table_privilege('authenticated', 'public.answer_options', 'select'), 'Hosts dürfen answer_options lesen';
  assert not has_table_privilege('anon', 'public.answer_options', 'select'), 'anon darf answer_options nicht lesen';
  assert not has_function_privilege('anon', 'public.host_save_quiz(jsonb)', 'execute'), 'anon darf host_save_quiz nicht ausführen';

  -- ohne Host-Login
  perform set_config('request.jwt.claims', '{}', true);
  assert public.host_save_quiz('{"title":"x","questions":[]}')->>'error' = 'NOT_HOST', 'speichern ohne Login';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_host)::text, true);

  -- Validierung
  assert public.host_save_quiz('{"title":"  ","questions":[]}')->>'error' = 'INVALID_TITLE', 'leerer Titel';
  assert public.host_save_quiz('{"title":"x"}')->>'error' = 'INVALID_QUIZ', 'fehlende Fragenliste';
  assert public.host_save_quiz('{"title":"x","questions":[{"text":"","max_selections":1,"options":[{"label":"a","points":1},{"label":"b","points":0}]}]}')->>'error' = 'INVALID_QUESTION', 'leerer Fragetext';
  assert public.host_save_quiz('{"title":"x","questions":[{"text":"f","max_selections":1,"options":[{"label":"a","points":1}]}]}')->>'error' = 'INVALID_OPTIONS', 'nur eine Antwort';
  assert public.host_save_quiz('{"title":"x","questions":[{"text":"f","max_selections":3,"options":[{"label":"a","points":1},{"label":"b","points":0}]}]}')->>'error' = 'INVALID_MAX_SELECTIONS', 'max_selections größer als Anzahl';
  assert public.host_save_quiz('{"title":"x","questions":[{"text":"f","max_selections":1,"options":[{"label":"a","points":"viel"},{"label":"b","points":0}]}]}')->>'error' = 'INVALID_POINTS', 'Punkte keine Zahl';
  assert public.host_save_quiz('{"title":"x","questions":[{"text":"f","max_selections":1,"options":[{"label":"","points":1},{"label":"b","points":0}]}]}')->>'error' = 'INVALID_LABEL', 'leere Antwort';
  r := public.host_save_quiz('{"title":"x","questions":[{"text":"ok","max_selections":1,"options":[{"label":"a","points":1},{"label":"b","points":0}]},{"text":"","max_selections":1,"options":[]}]}');
  assert (r->>'question')::int = 2, 'Fehler nennt die Nummer der Frage: ' || r::text;
  assert (select count(*) from public.quizzes where title = 'x') = 0, 'ungültiges Quiz darf nichts anlegen';

  -- neu anlegen
  r := public.host_save_quiz(jsonb_build_object(
    'title', '  __editor_selftest__  ',
    'questions', jsonb_build_array(
      jsonb_build_object('text', 'Frage A', 'max_selections', 1, 'options', jsonb_build_array(
        jsonb_build_object('label', 'A1', 'points', 0),
        jsonb_build_object('label', 'A2', 'points', -4),
        jsonb_build_object('label', 'A3', 'points', 10))),
      jsonb_build_object('text', 'Frage B', 'max_selections', 2, 'options', jsonb_build_array(
        jsonb_build_object('label', 'B1', 'points', 1),
        jsonb_build_object('label', 'B2', 'points', 2))))));
  assert (r->>'ok')::boolean, 'neu anlegen: ' || r::text;
  v_quiz := (r->>'quiz_id')::uuid;
  assert (select title from public.quizzes where id = v_quiz) = '__editor_selftest__', 'Titel getrimmt';
  assert (select count(*) from public.questions where quiz_id = v_quiz) = 2, '2 Fragen';

  select id into v_q1 from public.questions where quiz_id = v_quiz and position = 1;
  select id into v_q2 from public.questions where quiz_id = v_quiz and position = 2;
  select id into v_o1 from public.answer_options where question_id = v_q1 and position = 1;
  select id into v_o2 from public.answer_options where question_id = v_q1 and position = 2;
  select id into v_o3 from public.answer_options where question_id = v_q1 and position = 3;
  assert (select points from public.answer_options where id = v_o2) = -4, 'negative Punkte gespeichert';

  -- ändern: Fragen tauschen, eine Antwort löschen, eine umsortieren, eine neu, Punkte ändern
  r := public.host_save_quiz(jsonb_build_object(
    'id', v_quiz,
    'title', '__editor_selftest__',
    'questions', jsonb_build_array(
      jsonb_build_object('id', v_q2, 'text', 'Frage B neu', 'max_selections', 1, 'options', jsonb_build_array(
        jsonb_build_object('label', 'B neu 1', 'points', 3),
        jsonb_build_object('label', 'B neu 2', 'points', 4))),
      jsonb_build_object('id', v_q1, 'text', 'Frage A', 'max_selections', 2, 'options', jsonb_build_array(
        jsonb_build_object('id', v_o3, 'label', 'A3', 'points', 7),
        jsonb_build_object('id', v_o1, 'label', 'A1', 'points', 0),
        jsonb_build_object('label', 'A4', 'points', 1))))));
  assert (r->>'ok')::boolean, 'ändern: ' || r::text;
  assert (select position from public.questions where id = v_q2) = 1, 'Frage B steht jetzt vorn';
  assert (select position from public.questions where id = v_q1) = 2, 'Frage A steht jetzt hinten';
  assert (select text from public.questions where id = v_q2) = 'Frage B neu', 'Fragetext geändert';
  assert (select max_selections from public.questions where id = v_q1) = 2, 'max_selections geändert';
  assert not exists (select 1 from public.answer_options where id = v_o2), 'gelöschte Antwort ist weg';
  assert (select position from public.answer_options where id = v_o3) = 1, 'A3 steht jetzt vorn';
  assert (select points from public.answer_options where id = v_o3) = 7, 'Punkte geändert';
  assert (select count(*) from public.answer_options where question_id = v_q1) = 3, 'Frage A hat 3 Antworten';
  assert (select count(*) from public.answer_options where question_id = v_q2) = 2, 'Frage B hat 2 neue Antworten';
  assert (select count(*) from public.questions where quiz_id = v_quiz) = 2, 'weiterhin 2 Fragen, keine Duplikate';

  -- fremde IDs werden nicht übernommen, sondern als neu behandelt
  r := public.host_save_quiz(jsonb_build_object(
    'title', '__editor_selftest_2__',
    'questions', jsonb_build_array(
      jsonb_build_object('id', v_q1, 'text', 'kopiert', 'max_selections', 1, 'options', jsonb_build_array(
        jsonb_build_object('id', v_o1, 'label', 'k1', 'points', 1),
        jsonb_build_object('label', 'k2', 'points', 2))))));
  assert (r->>'ok')::boolean, 'Kopie mit fremden IDs: ' || r::text;
  assert (select quiz_id from public.questions where id = v_q1) = v_quiz, 'Original-Frage bleibt beim Original-Quiz';
  assert (select label from public.answer_options where id = v_o1) = 'A1', 'Original-Antwort unverändert';
  assert (public.host_delete_quiz((r->>'quiz_id')::uuid)->>'ok')::boolean, 'Kopie löschen';

  -- Sperre während einer Session
  r := public.host_create_session(v_quiz);
  v_session := (r->>'session_id')::uuid;
  v_ver := (r->>'version')::int;
  r := public.host_save_quiz(jsonb_build_object('id', v_quiz, 'title', 'gesperrt', 'questions', jsonb_build_array(
    jsonb_build_object('text', 'f', 'max_selections', 1, 'options', jsonb_build_array(
      jsonb_build_object('label', 'a', 'points', 1), jsonb_build_object('label', 'b', 'points', 2))))));
  assert r->>'error' = 'QUIZ_LOCKED', 'Quiz ist während einer Session gesperrt: ' || r::text;
  assert (select title from public.quizzes where id = v_quiz) = '__editor_selftest__', 'gesperrtes Quiz unverändert';
  assert public.host_delete_quiz(v_quiz)->>'error' = 'QUIZ_HAS_SESSIONS', 'Quiz mit Session nicht löschbar';

  -- laufende Session ist nicht löschbar, Lobby und beendete schon
  r := public.host_action(v_session, v_ver, 'OPEN_NEXT');
  v_ver := (r->>'version')::int;
  assert public.host_delete_session(v_session)->>'error' = 'SESSION_ACTIVE', 'laufende Session nicht löschbar';

  -- eine gespielte Frage kann nicht gelöscht werden; nichts wird halb gespeichert
  r := public.host_action(v_session, v_ver, 'END');
  r := public.host_save_quiz(jsonb_build_object('id', v_quiz, 'title', 'halb', 'questions', jsonb_build_array(
    jsonb_build_object('text', 'ganz neu', 'max_selections', 1, 'options', jsonb_build_array(
      jsonb_build_object('label', 'a', 'points', 1), jsonb_build_object('label', 'b', 'points', 2))))));
  assert r->>'error' = 'QUESTION_IN_USE', 'gespielte Frage nicht löschbar: ' || r::text;
  assert (select title from public.quizzes where id = v_quiz) = '__editor_selftest__', 'fehlgeschlagenes Speichern ändert nichts';
  assert (select count(*) from public.questions where quiz_id = v_quiz) = 2, 'weiterhin 2 Fragen';

  -- aufräumen über die Host-Funktionen
  assert (public.host_delete_session(v_session)->>'ok')::boolean, 'beendete Session löschen';
  assert (public.host_delete_quiz(v_quiz)->>'ok')::boolean, 'Quiz löschen';
  assert not exists (select 1 from public.questions where quiz_id = v_quiz), 'Fragen sind mit gelöscht';
end;
$$;

select 'Editor Selftest: alle Checks bestanden' as ergebnis;
