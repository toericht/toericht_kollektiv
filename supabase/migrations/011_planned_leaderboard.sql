-- töricht live – eingeplanter Zwischenstand
-- Im Supabase SQL Editor ausführen (nach 001–010). Kann wiederholt ausgeführt werden.
--
-- * Neue Art "leaderboard" in der Reihenfolge eines Quiz. Kommt sie bei "weiter"
--   an die Reihe, zeigt die Session den Zwischenstand (Zustand LEADERBOARD).
--   So erscheint der Zwischenstand nur dort, wo er im Editor eingeplant ist.
-- * Ein Zwischenstand hat keine Antworten, keinen Text und keine Medien, nimmt
--   keine Antworten an und bekommt keinen Zeiteintrag – er kann Punkte,
--   Antwortzeiten und Tie-Breaker nicht beeinflussen.
-- * submit_answer, get_state, presenter_get_state und session_scores bleiben
--   unverändert.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

alter table public.questions drop constraint if exists questions_kind_check;
alter table public.questions add constraint questions_kind_check
  check (kind in ('question', 'poll', 'slide', 'leaderboard'));

-- Fragen und Umfragen brauchen einen Text; Slides und Zwischenstände nicht.
alter table public.questions drop constraint if exists questions_text_check;
alter table public.questions add constraint questions_text_check
  check (char_length(text) <= 1000 and (kind in ('slide', 'leaderboard') or char_length(text) >= 1));

-- ---------------------------------------------------------------------------
-- host_action: "weiter" auf einen Zwischenstand zeigt die Rangliste
-- ---------------------------------------------------------------------------

create or replace function public.host_action(p_session_id uuid, p_expected_version int, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_s         public.game_sessions;
  v_new_state public.game_state;
  v_new_q     uuid;
  v_new_kind  text;
  v_cur_kind  text;
  v_now       timestamptz;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  select * into v_s from public.game_sessions s where s.id = p_session_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
  end if;
  if v_s.version is distinct from p_expected_version then
    return jsonb_build_object('ok', false, 'error', 'VERSION_MISMATCH',
                              'version', v_s.version, 'state', v_s.state);
  end if;

  -- Uhr erst nach der Sperre lesen: Alle bis hierher angenommenen Antworten
  -- haben eine frühere Zeit.
  v_now := clock_timestamp();
  v_new_state := v_s.state;
  v_new_q := v_s.current_question_id;

  select q.kind into v_cur_kind from public.questions q where q.id = v_s.current_question_id;

  case p_action
    when 'OPEN_NEXT' then
      if v_s.state not in ('LOBBY', 'SLIDE', 'QUESTION_CLOSED', 'RESULTS', 'LEADERBOARD') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_q := null;
      if v_s.current_question_id is null then
        select q.id, q.kind into v_new_q, v_new_kind from public.questions q
        where q.quiz_id = v_s.quiz_id
        order by q.position, q.id
        limit 1;
      else
        select q.id, q.kind into v_new_q, v_new_kind
        from public.questions q
        join public.questions c on c.id = v_s.current_question_id
        where q.quiz_id = v_s.quiz_id and (q.position, q.id) > (c.position, c.id)
        order by q.position, q.id
        limit 1;
      end if;
      if v_new_q is null then
        return jsonb_build_object('ok', false, 'error', 'NO_MORE_QUESTIONS');
      end if;
      if v_new_kind = 'slide' then
        v_new_state := 'SLIDE';
      elsif v_new_kind = 'leaderboard' then
        -- im Editor eingeplanter Zwischenstand
        v_new_state := 'LEADERBOARD';
      else
        v_new_state := 'QUESTION_OPEN';
      end if;

    when 'CLOSE' then
      if v_s.state <> 'QUESTION_OPEN' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'QUESTION_CLOSED';

    when 'REOPEN' then
      if v_s.state <> 'QUESTION_CLOSED' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'QUESTION_OPEN';

    when 'SHOW_RESULTS' then
      if v_s.state = 'QUESTION_CLOSED' then
        v_new_state := 'RESULTS';
      elsif v_s.state = 'LEADERBOARD' then
        -- "Leaderboard verstecken": zurück zu dem, was vorher zu sehen war
        if v_cur_kind = 'slide' then
          v_new_state := 'SLIDE';
        elsif v_cur_kind = 'leaderboard' then
          -- ein eingeplanter Zwischenstand hat keine Ansicht dahinter
          return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
        else
          v_new_state := 'RESULTS';
        end if;
      else
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;

    when 'SHOW_LEADERBOARD' then
      if v_s.state not in ('QUESTION_CLOSED', 'RESULTS', 'SLIDE') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'LEADERBOARD';

    when 'SHOW_FINAL' then
      if v_s.state not in ('QUESTION_CLOSED', 'RESULTS', 'LEADERBOARD', 'SLIDE') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'FINAL_RESULTS';

    when 'END' then
      if v_s.state = 'ENDED' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'ENDED';

    else
      return jsonb_build_object('ok', false, 'error', 'UNKNOWN_ACTION');
  end case;

  -- Öffnungsdauer mitführen – nur für Fragen, nie für Slides
  if v_s.state = 'QUESTION_OPEN' and v_new_state <> 'QUESTION_OPEN' then
    -- Frage wird geschlossen (CLOSE oder END): laufende Phase abschließen
    update public.session_questions sq
    set open_ms = sq.open_ms
                  + greatest((extract(epoch from (v_now - sq.last_opened_at)) * 1000)::bigint, 0),
        last_opened_at = null
    where sq.session_id = v_s.id
      and sq.question_id = v_s.current_question_id
      and sq.last_opened_at is not null;
  elsif p_action = 'OPEN_NEXT' and v_new_kind = 'question' then
    insert into public.session_questions (session_id, question_id, open_ms, last_opened_at, first_opened_at)
    values (v_s.id, v_new_q, 0, v_now, v_now)
    on conflict (session_id, question_id) do update set last_opened_at = excluded.last_opened_at;
  elsif p_action = 'REOPEN' then
    -- die Uhr läuft weiter; open_ms bleibt, die Pause zählt nicht
    update public.session_questions sq
    set last_opened_at = v_now
    where sq.session_id = v_s.id and sq.question_id = v_s.current_question_id;
  end if;

  update public.game_sessions s
  set state = v_new_state,
      current_question_id = v_new_q,
      version = s.version + 1,
      state_changed_at = now(),
      ended_at = case when v_new_state = 'ENDED' then now() else s.ended_at end
  where s.id = v_s.id
  returning * into v_s;

  perform private.notify_session(v_s.id, v_s.version);

  return jsonb_build_object('ok', true, 'version', v_s.version, 'state', v_s.state,
                            'current_question_id', v_s.current_question_id);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- host_get_state: liefert zusätzlich die Art des aktuellen Eintrags
-- ---------------------------------------------------------------------------

create or replace function public.host_get_state(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_s      public.game_sessions;
  v_q      public.questions;
  v_next   public.questions;
  v_result jsonb;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  select * into v_s from public.game_sessions s where s.id = p_session_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
  end if;

  if v_s.current_question_id is not null then
    select * into v_q from public.questions q where q.id = v_s.current_question_id;
    select q.* into v_next from public.questions q
    where q.quiz_id = v_s.quiz_id and (q.position, q.id) > (v_q.position, v_q.id)
    order by q.position, q.id
    limit 1;
  else
    select q.* into v_next from public.questions q
    where q.quiz_id = v_s.quiz_id
    order by q.position, q.id
    limit 1;
  end if;

  v_result := jsonb_build_object(
    'ok', true,
    'session', jsonb_build_object(
      'id', v_s.id,
      'join_code', v_s.join_code,
      'state', v_s.state,
      'version', v_s.version,
      'join_locked', v_s.join_locked,
      'quiz_id', v_s.quiz_id,
      'quiz_title', (select z.title from public.quizzes z where z.id = v_s.quiz_id),
      'created_at', v_s.created_at
    ),
    'question_total', (select count(*) from public.questions q
                       where q.quiz_id = v_s.quiz_id and q.kind = 'question'),
    -- was als Nächstes kommt (für den Weiter-Knopf)
    'next', case when v_next.id is null then null
                 else jsonb_build_object('kind', v_next.kind, 'images', to_jsonb(v_next.image_paths)) end,
    'player_count', (select count(*) from public.players p
                     where p.session_id = v_s.id and not p.removed),
    'connected_count', (select count(*) from public.players p
                        where p.session_id = v_s.id and not p.removed
                          and p.last_seen_at > now() - interval '20 seconds'),
    'players', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', s.player_id,
               'name', s.display_name,
               'score', s.score,
               'time_ms', s.time_ms,
               'tied', s.tied,
               'rank', s.rank,
               'connected', s.last_seen_at > now() - interval '20 seconds',
               'removed', s.removed,
               'joined_at', s.joined_at
             ) order by s.removed, s.rank, s.joined_at), '[]'::jsonb)
      from private.session_scores(v_s.id) s)
  );

  if v_q.id is not null then
    v_result := v_result || jsonb_build_object(
      'current_kind', v_q.kind,
      'question_number', (select count(*) from public.questions q
                          where q.quiz_id = v_q.quiz_id and q.kind = 'question'
                            and (q.position, q.id) <= (v_q.position, v_q.id)));

    if v_q.kind = 'leaderboard' then
      null; -- eingeplanter Zwischenstand: die Rangliste steht in "players"
    elsif v_q.kind = 'slide' then
      v_result := v_result || jsonb_build_object(
        'slide', jsonb_build_object(
          'id', v_q.id,
          'heading', v_q.heading,
          'text', v_q.text,
          'images', to_jsonb(v_q.image_paths),
          'media', v_q.media));
    else
      v_result := v_result || jsonb_build_object(
        'answered_count', (select count(*)
                           from public.player_answers a
                           join public.players p on p.id = a.player_id
                           where a.session_id = v_s.id and a.question_id = v_q.id and not p.removed),
        'question', jsonb_build_object(
          'id', v_q.id,
          'kind', v_q.kind,
          'text', v_q.text,
          'max_selections', v_q.max_selections,
          'images', to_jsonb(v_q.image_paths),
          'media', v_q.media,
          'options', (
            select coalesce(jsonb_agg(jsonb_build_object(
                     'id', o.id,
                     'label', o.label,
                     'points', o.points,
                     'count', (select count(*)
                               from public.player_answers a
                               join public.players p on p.id = a.player_id
                               where a.session_id = v_s.id
                                 and a.question_id = v_q.id
                                 and not p.removed
                                 and o.id = any (a.option_ids))
                   ) order by o.position, o.id), '[]'::jsonb)
            from public.answer_options o where o.question_id = v_q.id)
        )
      );
    end if;
  end if;

  return v_result;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- host_save_quiz: Art "leaderboard"
-- ---------------------------------------------------------------------------

create or replace function public.host_save_quiz(p_quiz jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_quiz_id uuid;
  v_title   text := btrim(coalesce(p_quiz->>'title', ''));
  v_items   jsonb := coalesce(p_quiz->'items', p_quiz->'questions');
  v_q       jsonb;
  v_o       jsonb;
  v_qpos    bigint;
  v_opos    bigint;
  v_qid     uuid;
  v_oid     uuid;
  v_kind    text;
  v_text    text;
  v_heading text;
  v_images  text[];
  v_media   jsonb;
  v_keep_q  uuid[] := '{}';
  v_keep_o  uuid[];
  v_before  text[] := '{}';
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
  if jsonb_typeof(v_items) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'error', 'INVALID_QUIZ');
  end if;

  for v_q, v_qpos in
    select t.value, t.ordinality from jsonb_array_elements(v_items) with ordinality as t
  loop
    v_kind := coalesce(v_q->>'kind', 'question');
    v_text := btrim(coalesce(v_q->>'text', ''));
    if v_kind not in ('question', 'poll', 'slide', 'leaderboard') then
      return jsonb_build_object('ok', false, 'error', 'INVALID_ITEM', 'question', v_qpos);
    end if;

    if v_q ? 'images' and jsonb_typeof(v_q->'images') <> 'null' then
      if jsonb_typeof(v_q->'images') <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'INVALID_IMAGES', 'question', v_qpos);
      end if;
      if jsonb_array_length(v_q->'images') > 6
         or exists (select 1 from jsonb_array_elements(v_q->'images') as t
                    where jsonb_typeof(t.value) <> 'string'
                       or (t.value #>> '{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg|png)$') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_IMAGES', 'question', v_qpos);
      end if;
    end if;

    v_media := private.clean_media(v_q->'media', v_kind);
    if v_media is null then
      return jsonb_build_object('ok', false, 'error', 'INVALID_MEDIA', 'question', v_qpos);
    end if;

    if v_kind = 'leaderboard' then
      -- ein Zwischenstand hat keine Antworten; Text, Bilder und Medien werden ignoriert
      if jsonb_typeof(v_q->'options') = 'array' and jsonb_array_length(v_q->'options') > 0 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_LEADERBOARD', 'question', v_qpos);
      end if;
    elsif v_kind = 'slide' then
      if char_length(v_text) > 1000 or char_length(btrim(coalesce(v_q->>'heading', ''))) > 200 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_SLIDE', 'question', v_qpos);
      end if;
      -- eine Slide hat nie Antworten
      if jsonb_typeof(v_q->'options') = 'array' and jsonb_array_length(v_q->'options') > 0 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_SLIDE', 'question', v_qpos);
      end if;
      -- und braucht irgendeinen Inhalt
      if v_text = '' and btrim(coalesce(v_q->>'heading', '')) = ''
         and coalesce(jsonb_array_length(nullif(v_q->'images', 'null'::jsonb)), 0) = 0
         and v_media = '{}'::jsonb then
        return jsonb_build_object('ok', false, 'error', 'EMPTY_SLIDE', 'question', v_qpos);
      end if;
    else
      if char_length(v_text) not between 1 and 500 then
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
        -- bei Umfragen werden Punkte ignoriert und als 0 gespeichert
        if v_kind = 'question' and coalesce(v_o->>'points', '') !~ '^-?\d{1,6}$' then
          return jsonb_build_object('ok', false, 'error', 'INVALID_POINTS', 'question', v_qpos);
        end if;
      end loop;
    end if;
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

    v_before := private.quiz_files(v_quiz_id);

    update public.quizzes z set title = v_title, updated_at = now() where z.id = v_quiz_id;
  end if;

  for v_q, v_qpos in
    select t.value, t.ordinality from jsonb_array_elements(v_items) with ordinality as t
  loop
    v_kind := coalesce(v_q->>'kind', 'question');
    v_text := btrim(coalesce(v_q->>'text', ''));
    v_heading := case when v_kind = 'slide' then nullif(btrim(coalesce(v_q->>'heading', '')), '') end;
    v_media := private.clean_media(v_q->'media', v_kind);
    select coalesce(array_agg(t.value order by t.ordinality), '{}'::text[]) into v_images
    from jsonb_array_elements_text(
           case when jsonb_typeof(v_q->'images') = 'array' then v_q->'images' else '[]'::jsonb end
         ) with ordinality as t;
    if v_kind = 'leaderboard' then
      v_text := '';
      v_media := '{}'::jsonb;
      v_images := '{}';
    end if;

    v_qid := nullif(v_q->>'id', '')::uuid;
    if v_qid is not null then
      update public.questions q
      set position = v_qpos, kind = v_kind, text = v_text, heading = v_heading,
          image_paths = v_images, media = v_media,
          max_selections = case when v_kind in ('slide', 'leaderboard') then 1 else (v_q->>'max_selections')::int end
      where q.id = v_qid and q.quiz_id = v_quiz_id;
      if not found then v_qid := null; end if;
    end if;
    if v_qid is null then
      insert into public.questions (quiz_id, position, kind, text, heading, image_paths, media, max_selections)
      values (v_quiz_id, v_qpos, v_kind, v_text, v_heading, v_images, v_media,
              case when v_kind in ('slide', 'leaderboard') then 1 else (v_q->>'max_selections')::int end)
      returning id into v_qid;
    end if;
    v_keep_q := v_keep_q || v_qid;

    v_keep_o := '{}';
    if v_kind in ('question', 'poll') then
      for v_o, v_opos in
        select t.value, t.ordinality from jsonb_array_elements(v_q->'options') with ordinality as t
      loop
        v_oid := nullif(v_o->>'id', '')::uuid;
        if v_oid is not null then
          update public.answer_options o
          set position = v_opos, label = btrim(v_o->>'label'),
              points = case when v_kind = 'poll' then 0 else (v_o->>'points')::int end
          where o.id = v_oid and o.question_id = v_qid;
          if not found then v_oid := null; end if;
        end if;
        if v_oid is null then
          insert into public.answer_options (question_id, position, label, points)
          values (v_qid, v_opos, btrim(v_o->>'label'),
                  case when v_kind = 'poll' then 0 else (v_o->>'points')::int end)
          returning id into v_oid;
        end if;
        v_keep_o := v_keep_o || v_oid;
      end loop;
    end if;

    -- bei Slides und Zwischenständen bleibt v_keep_o leer: alle Antworten werden entfernt
    delete from public.answer_options o where o.question_id = v_qid and o.id <> all (v_keep_o);
  end loop;

  delete from public.questions q where q.quiz_id = v_quiz_id and q.id <> all (v_keep_q);

  -- removed_images enthält alle Dateien (Bild, Video, Audio), die kein Quiz mehr verwendet
  return jsonb_build_object('ok', true, 'quiz_id', v_quiz_id,
                            'removed_images', to_jsonb(private.unused_images(v_before)));
exception
  -- ein Eintrag wird noch von einer gespielten Session referenziert
  when foreign_key_violation then
    return jsonb_build_object('ok', false, 'error', 'QUESTION_IN_USE');
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'error', 'INVALID_QUIZ');
end;
$fn$;
