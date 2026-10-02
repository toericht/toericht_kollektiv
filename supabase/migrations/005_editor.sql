-- töricht live – Phase 6: Quiz-Editor
-- Im Supabase SQL Editor ausführen (nach 001–004). Kann wiederholt ausgeführt werden.
--
-- Der Editor speichert ein Quiz immer als Ganzes in einer Transaktion.
-- Direktes Schreiben in die Quiz-Tabellen ist für Hosts deshalb nicht mehr nötig
-- und wird entzogen; Lesen (inklusive Punktwerten) bleibt für Hosts erlaubt.

revoke insert, update, delete on table public.quizzes, public.questions, public.answer_options from authenticated;

-- ---------------------------------------------------------------------------
-- Quiz speichern (neu anlegen oder vollständig ersetzen)
-- ---------------------------------------------------------------------------
--
-- p_quiz: {
--   "id": "<uuid>" | null,
--   "title": "...",
--   "questions": [
--     { "id": "<uuid>" | null, "text": "...", "max_selections": 1,
--       "options": [ { "id": "<uuid>" | null, "label": "...", "points": 5 } ] }
--   ]
-- }
-- Die Reihenfolge der Arrays bestimmt die Reihenfolge im Spiel. Fragen und
-- Antworten, die nicht mehr enthalten sind, werden gelöscht.
create or replace function public.host_save_quiz(p_quiz jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quiz_id uuid;
  v_title   text := btrim(coalesce(p_quiz->>'title', ''));
  v_q       jsonb;
  v_o       jsonb;
  v_qpos    bigint;
  v_opos    bigint;
  v_qid     uuid;
  v_oid     uuid;
  v_keep_q  uuid[] := '{}';
  v_keep_o  uuid[];
  v_count   int;
  v_locked  text;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  -- erst alles prüfen, dann schreiben
  if char_length(v_title) not between 1 and 200 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_TITLE');
  end if;
  if jsonb_typeof(p_quiz->'questions') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_QUIZ');
  end if;

  for v_q, v_qpos in
    select t.value, t.ordinality from jsonb_array_elements(p_quiz->'questions') with ordinality as t
  loop
    if char_length(btrim(coalesce(v_q->>'text', ''))) not between 1 and 500 then
      return jsonb_build_object('ok', false, 'error', 'INVALID_QUESTION', 'question', v_qpos);
    end if;
    if jsonb_typeof(v_q->'options') is distinct from 'array' or jsonb_array_length(v_q->'options') < 2 then
      return jsonb_build_object('ok', false, 'error', 'INVALID_OPTIONS', 'question', v_qpos);
    end if;
    v_count := jsonb_array_length(v_q->'options');
    if coalesce(v_q->>'max_selections', '') !~ '^\d{1,3}$'
       or (v_q->>'max_selections')::int not between 1 and v_count then
      return jsonb_build_object('ok', false, 'error', 'INVALID_MAX_SELECTIONS', 'question', v_qpos);
    end if;
    for v_o in select t.value from jsonb_array_elements(v_q->'options') as t loop
      if char_length(btrim(coalesce(v_o->>'label', ''))) not between 1 and 200 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_LABEL', 'question', v_qpos);
      end if;
      if coalesce(v_o->>'points', '') !~ '^-?\d{1,6}$' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_POINTS', 'question', v_qpos);
      end if;
    end loop;
  end loop;

  v_quiz_id := nullif(p_quiz->>'id', '')::uuid;

  if v_quiz_id is null then
    insert into public.quizzes (title) values (v_title) returning id into v_quiz_id;
  else
    perform 1 from public.quizzes z where z.id = v_quiz_id for update;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'QUIZ_NOT_FOUND');
    end if;

    -- solange eine Session läuft, darf sich das Quiz nicht ändern
    select s.join_code into v_locked from public.game_sessions s
    where s.quiz_id = v_quiz_id and s.state <> 'ENDED'
    limit 1;
    if v_locked is not null then
      return jsonb_build_object('ok', false, 'error', 'QUIZ_LOCKED', 'join_code', v_locked);
    end if;

    update public.quizzes z set title = v_title, updated_at = now() where z.id = v_quiz_id;
  end if;

  for v_q, v_qpos in
    select t.value, t.ordinality from jsonb_array_elements(p_quiz->'questions') with ordinality as t
  loop
    v_qid := nullif(v_q->>'id', '')::uuid;
    if v_qid is not null then
      update public.questions q
      set position = v_qpos, text = btrim(v_q->>'text'), max_selections = (v_q->>'max_selections')::int
      where q.id = v_qid and q.quiz_id = v_quiz_id;
      if not found then v_qid := null; end if;
    end if;
    if v_qid is null then
      insert into public.questions (quiz_id, position, text, max_selections)
      values (v_quiz_id, v_qpos, btrim(v_q->>'text'), (v_q->>'max_selections')::int)
      returning id into v_qid;
    end if;
    v_keep_q := v_keep_q || v_qid;

    v_keep_o := '{}';
    for v_o, v_opos in
      select t.value, t.ordinality from jsonb_array_elements(v_q->'options') with ordinality as t
    loop
      v_oid := nullif(v_o->>'id', '')::uuid;
      if v_oid is not null then
        update public.answer_options o
        set position = v_opos, label = btrim(v_o->>'label'), points = (v_o->>'points')::int
        where o.id = v_oid and o.question_id = v_qid;
        if not found then v_oid := null; end if;
      end if;
      if v_oid is null then
        insert into public.answer_options (question_id, position, label, points)
        values (v_qid, v_opos, btrim(v_o->>'label'), (v_o->>'points')::int)
        returning id into v_oid;
      end if;
      v_keep_o := v_keep_o || v_oid;
    end loop;

    delete from public.answer_options o where o.question_id = v_qid and o.id <> all (v_keep_o);
  end loop;

  delete from public.questions q where q.quiz_id = v_quiz_id and q.id <> all (v_keep_q);

  return jsonb_build_object('ok', true, 'quiz_id', v_quiz_id);
exception
  -- eine Frage wird noch von einer gespielten Session referenziert
  when foreign_key_violation then
    return jsonb_build_object('ok', false, 'error', 'QUESTION_IN_USE');
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'error', 'INVALID_QUIZ');
end;
$$;

-- ---------------------------------------------------------------------------
-- Quiz und Sessions löschen
-- ---------------------------------------------------------------------------

create or replace function public.host_delete_quiz(p_quiz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;
  if exists (select 1 from public.game_sessions s where s.quiz_id = p_quiz_id) then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_HAS_SESSIONS');
  end if;

  delete from public.quizzes z where z.id = p_quiz_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_NOT_FOUND');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Löscht eine Session samt Personen, Antworten und Recovery-Codes.
-- Laufende Spiele müssen vorher beendet werden.
create or replace function public.host_delete_session(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state public.game_state;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  select s.state into v_state from public.game_sessions s where s.id = p_session_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
  end if;
  if v_state not in ('LOBBY', 'ENDED') then
    return jsonb_build_object('ok', false, 'error', 'SESSION_ACTIVE');
  end if;

  delete from public.game_sessions s where s.id = p_session_id;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.host_save_quiz(jsonb) from public, anon;
revoke all on function public.host_delete_quiz(uuid) from public, anon;
revoke all on function public.host_delete_session(uuid) from public, anon;

grant execute on function public.host_save_quiz(jsonb) to authenticated;
grant execute on function public.host_delete_quiz(uuid) to authenticated;
grant execute on function public.host_delete_session(uuid) to authenticated;
