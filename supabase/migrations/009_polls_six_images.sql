-- töricht live – Umfragen und bis zu 6 Bilder
-- Im Supabase SQL Editor ausführen (nach 001–008). Kann wiederholt ausgeführt werden.
--
-- * Neue Art "poll" (Umfrage) neben "question" und "slide". Eine Umfrage läuft
--   durch dieselben Zustände wie eine Frage (offen → geschlossen → Ergebnisse),
--   zählt aber nie zur Wertung:
--     - submit_answer speichert für Umfragen immer 0 Punkte und 0 ms,
--     - für Umfragen entsteht kein Zeiteintrag in session_questions,
--     - session_scores summiert Punkte und Zeiten nur über kind = 'question'.
--   Damit kann auch ein manipulierter Request weder Punkte noch Zeit erzeugen.
-- * Ergebnisse werden serverseitig aggregiert (Anzahl pro Antwort, Anzahl der
--   Personen mit Antwort). Bei Umfragen markiert "top" die meistgewählte(n).
-- * 0–6 Bilder pro Frage, Umfrage oder Slide.
-- * host_action bleibt unverändert: alles, was keine Slide ist, wird geöffnet;
--   einen Zeiteintrag gibt es dort schon bisher nur für kind = 'question'.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- bisherige Regeln für kind und image_paths entfernen, egal wie sie heißen
do $$
declare
  c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.questions'::regclass and contype = 'c'
      and (pg_get_constraintdef(oid) like '%kind = ANY%' or pg_get_constraintdef(oid) like '%image_paths%')
  loop
    execute format('alter table public.questions drop constraint %I', c.conname);
  end loop;
end;
$$;

alter table public.questions add constraint questions_kind_check
  check (kind in ('question', 'poll', 'slide'));
alter table public.questions add constraint questions_image_paths_check
  check (cardinality(image_paths) <= 6);

-- ---------------------------------------------------------------------------
-- Scores: nur gewertete Fragen zählen, für Punkte wie für Zeit
-- ---------------------------------------------------------------------------

create or replace function private.session_scores(p_session_id uuid)
returns table (
  player_id    uuid,
  display_name text,
  score        bigint,
  time_ms      bigint,
  tied         boolean,
  rank         bigint,
  joined_at    timestamptz,
  last_seen_at timestamptz,
  removed      boolean
)
language sql
set search_path = ''
as $fn$
  with sq as (
    select q.question_id,
           q.open_ms + case
             when q.last_opened_at is null then 0
             else greatest((extract(epoch from (clock_timestamp() - q.last_opened_at)) * 1000)::bigint, 0)
           end as duration_ms
    from public.session_questions q
    join public.questions qq on qq.id = q.question_id and qq.kind = 'question'
    where q.session_id = p_session_id
  ),
  named as (
    select p.id, p.nickname, p.joined_at, p.last_seen_at, p.removed,
           row_number() over (partition by lower(p.nickname) order by p.joined_at, p.id) as n
    from public.players p
    where p.session_id = p_session_id
  ),
  scored as (
    select n.*,
           coalesce((select sum(a.points_awarded)
                     from public.player_answers a
                     join public.questions qq on qq.id = a.question_id and qq.kind = 'question'
                     where a.player_id = n.id), 0)::bigint as total,
           coalesce((select sum(coalesce(a.answer_ms, sq.duration_ms))
                     from sq
                     left join public.player_answers a
                       on a.question_id = sq.question_id and a.player_id = n.id), 0)::bigint as total_ms
    from named n
  )
  select s.id,
         case when s.n > 1 then s.nickname || ' (' || s.n || ')' else s.nickname end,
         s.total,
         s.total_ms,
         -- teilt die Punktzahl mit mindestens einer weiteren Person
         count(*) over (partition by s.removed, s.total) > 1,
         rank() over (partition by s.removed order by s.total desc, s.total_ms asc),
         s.joined_at,
         s.last_seen_at,
         s.removed
  from scored s;
$fn$;

revoke all on function private.session_scores(uuid) from public;

-- ---------------------------------------------------------------------------
-- host_create_session: mindestens eine Frage oder Umfrage
-- ---------------------------------------------------------------------------

create or replace function public.host_create_session(p_quiz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_session public.game_sessions;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;
  if not exists (select 1 from public.quizzes z where z.id = p_quiz_id) then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_NOT_FOUND');
  end if;
  if not exists (select 1 from public.questions q
                 where q.quiz_id = p_quiz_id and q.kind in ('question', 'poll')) then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_EMPTY');
  end if;

  loop
    begin
      insert into public.game_sessions (quiz_id, join_code, created_by)
      values (p_quiz_id, private.random_code(5), auth.uid())
      returning * into v_session;
      exit;
    exception when unique_violation then
      null; -- Join-Code schon vergeben, neu würfeln
    end;
  end loop;

  return jsonb_build_object('ok', true, 'session_id', v_session.id,
                            'join_code', v_session.join_code, 'version', v_session.version);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- submit_answer: Umfragen bekommen nie Punkte und nie eine Antwortzeit
-- ---------------------------------------------------------------------------

create or replace function public.submit_answer(
  p_token       text,
  p_question_id uuid,
  p_option_ids  uuid[],
  p_client_seq  bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_player  public.players;
  v_state   public.game_state;
  v_current uuid;
  v_version int;
  v_ids     uuid[];
  v_max     int;
  v_kind    text;
  v_valid   int;
  v_points  int;
  v_ms      bigint;
  v_seq     bigint := coalesce(p_client_seq, 0);
  v_row     public.player_answers;
begin
  select * into v_player from public.players p
  where p.token_hash = private.hash_secret(coalesce(p_token, ''));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'UNKNOWN_PLAYER');
  end if;
  if v_player.removed then
    return jsonb_build_object('ok', false, 'error', 'REMOVED');
  end if;

  select s.state, s.current_question_id, s.version
    into v_state, v_current, v_version
  from public.game_sessions s
  where s.id = v_player.session_id
  for share;

  if v_state <> 'QUESTION_OPEN' or v_current is distinct from p_question_id then
    return jsonb_build_object('ok', false, 'error', 'QUESTION_NOT_OPEN', 'version', v_version);
  end if;

  select q.max_selections, q.kind into v_max, v_kind from public.questions q where q.id = p_question_id;
  -- kann im Zustand QUESTION_OPEN nicht vorkommen; eine Slide nimmt nie Antworten an
  if v_kind is null or v_kind not in ('question', 'poll') then
    return jsonb_build_object('ok', false, 'error', 'QUESTION_NOT_OPEN', 'version', v_version);
  end if;

  -- Uhr erst nach der Sperre lesen: Der Host kann die Frage jetzt nicht mehr
  -- schließen, bevor diese Antwort gespeichert ist.
  select sq.open_ms + (extract(epoch from (clock_timestamp() - sq.last_opened_at)) * 1000)::bigint
    into v_ms
  from public.session_questions sq
  where sq.session_id = v_player.session_id and sq.question_id = p_question_id;
  v_ms := greatest(coalesce(v_ms, 0), 0);

  select coalesce(array_agg(distinct t.x order by t.x), '{}'::uuid[]) into v_ids
  from unnest(coalesce(p_option_ids, '{}'::uuid[])) as t (x)
  where t.x is not null;

  if cardinality(v_ids) < 1 or cardinality(v_ids) > v_max then
    return jsonb_build_object('ok', false, 'error', 'INVALID_SELECTION');
  end if;

  select count(*)::int, coalesce(sum(o.points), 0)::int into v_valid, v_points
  from public.answer_options o
  where o.question_id = p_question_id and o.id = any (v_ids);

  if v_valid <> cardinality(v_ids) then
    return jsonb_build_object('ok', false, 'error', 'INVALID_SELECTION');
  end if;

  -- Umfrage: unabhängig davon, was in der Datenbank oder im Request steht
  if v_kind = 'poll' then
    v_points := 0;
    v_ms := 0;
  end if;

  insert into public.player_answers as pa
    (session_id, player_id, question_id, option_ids, points_awarded, client_seq, answer_ms)
  values
    (v_player.session_id, v_player.id, p_question_id, v_ids, v_points, v_seq, v_ms)
  on conflict (player_id, question_id) do update
    set option_ids     = excluded.option_ids,
        points_awarded = excluded.points_awarded,
        client_seq     = excluded.client_seq,
        answer_ms      = excluded.answer_ms,
        updated_at     = now()
    where pa.client_seq < excluded.client_seq;

  select * into v_row from public.player_answers a
  where a.player_id = v_player.id and a.question_id = p_question_id;

  -- gibt immer die tatsächlich gespeicherte Antwort zurück
  return jsonb_build_object(
    'ok', true,
    'option_ids', to_jsonb(v_row.option_ids),
    'client_seq', v_row.client_seq
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- get_state: Art der Frage, aggregierte Ergebnisse, bei Umfragen "top"
-- ---------------------------------------------------------------------------

create or replace function public.get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_player  public.players;
  v_session public.game_sessions;
  v_q       public.questions;
  v_max     int;
  v_result  jsonb;
begin
  select * into v_player from public.players p
  where p.token_hash = private.hash_secret(coalesce(p_token, ''));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'UNKNOWN_PLAYER');
  end if;
  if v_player.removed then
    return jsonb_build_object('ok', false, 'error', 'REMOVED');
  end if;

  update public.players p set last_seen_at = now()
  where p.id = v_player.id and p.last_seen_at < now() - interval '3 seconds';

  select * into v_session from public.game_sessions s where s.id = v_player.session_id;

  v_result := jsonb_build_object(
    'ok', true,
    'session', jsonb_build_object(
      'id', v_session.id,
      'join_code', v_session.join_code,
      'state', v_session.state,
      'version', v_session.version
    ),
    'player', jsonb_build_object('id', v_player.id, 'nickname', v_player.nickname),
    'player_count', (select count(*) from public.players p
                     where p.session_id = v_session.id and not p.removed)
  );

  -- Slides haben den Zustand SLIDE und liefern hier bewusst keinen Inhalt.
  if v_session.state in ('QUESTION_OPEN', 'QUESTION_CLOSED', 'RESULTS')
     and v_session.current_question_id is not null then
    select * into v_q from public.questions q where q.id = v_session.current_question_id;

    v_result := v_result || jsonb_build_object(
      'question', jsonb_build_object(
        'id', v_q.id,
        'kind', v_q.kind,
        'text', v_q.text,
        'max_selections', v_q.max_selections,
        -- gezählt werden nur gewertete Fragen, keine Umfragen und Slides
        'number', (select count(*) from public.questions q
                   where q.quiz_id = v_q.quiz_id and q.kind = 'question'
                     and (q.position, q.id) <= (v_q.position, v_q.id)),
        'total', (select count(*) from public.questions q
                  where q.quiz_id = v_q.quiz_id and q.kind = 'question'),
        -- kleine Bildvariante fürs Handy: <uuid>.<ext> -> <uuid>_m.<ext>
        'images', (select coalesce(jsonb_agg(regexp_replace(t.p, '\.([a-z]+)$', '_m.\1') order by t.ord), '[]'::jsonb)
                   from unnest(v_q.image_paths) with ordinality as t (p, ord)),
        'options', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label)
                                              order by o.position, o.id), '[]'::jsonb)
                    from public.answer_options o where o.question_id = v_q.id)
      ),
      'my_answer', (select jsonb_build_object('option_ids', to_jsonb(a.option_ids),
                                              'client_seq', a.client_seq)
                    from public.player_answers a
                    where a.player_id = v_player.id and a.question_id = v_q.id)
    );

    if v_session.state = 'RESULTS' then
      select max(o.points) into v_max from public.answer_options o where o.question_id = v_q.id;

      v_result := v_result || jsonb_build_object(
        -- eigene Punkte für diese Frage; null ohne Antwort und bei Umfragen
        'my_question_score', case when v_q.kind = 'question' then
                               (select a.points_awarded from public.player_answers a
                                where a.player_id = v_player.id and a.question_id = v_q.id)
                             end,
        -- Personen, die überhaupt geantwortet haben (Basis für Prozentwerte)
        'answered_count', (select count(*)
                           from public.player_answers a
                           join public.players p on p.id = a.player_id
                           where a.session_id = v_session.id and a.question_id = v_q.id and not p.removed),
        'results', (
          with counts as (
            select o.id, o.position, o.points,
                   (select count(*)
                    from public.player_answers a
                    join public.players p on p.id = a.player_id
                    where a.session_id = v_session.id
                      and a.question_id = v_q.id
                      and not p.removed
                      and o.id = any (a.option_ids)) as cnt
            from public.answer_options o
            where o.question_id = v_q.id
          )
          select coalesce(jsonb_agg(
                   jsonb_build_object('option_id', c.id, 'count', c.cnt)
                   || case
                        -- Umfrage: meistgewählte Antwort(en), keine Punktestufen
                        when v_q.kind = 'poll' then jsonb_build_object(
                          'top', c.cnt > 0 and c.cnt = (select max(c2.cnt) from counts c2))
                        else jsonb_build_object(
                          'tier', case
                                    when c.points > 0 and c.points = v_max then 'best'
                                    when c.points > 0 then 'good'
                                    else 'bad'
                                  end)
                      end
                   order by c.position, c.id), '[]'::jsonb)
          from counts c)
      );
    end if;
  end if;

  if v_session.state in ('LEADERBOARD', 'FINAL_RESULTS', 'ENDED') then
    v_result := v_result || (
      with scores as materialized (
        select s.* from private.session_scores(v_session.id) s where not s.removed
      )
      select jsonb_build_object(
        'leaderboard', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'rank', t.rank, 'name', t.display_name, 'score', t.score,
                   'time_ms', t.time_ms, 'tied', t.tied,
                   'me', t.player_id = v_player.id
                 ) order by t.rank, t.joined_at), '[]'::jsonb)
          from (select * from scores order by rank, joined_at limit 10) t),
        'me', (select jsonb_build_object('rank', s.rank, 'name', s.display_name, 'score', s.score,
                                         'time_ms', s.time_ms, 'tied', s.tied)
               from scores s
               where s.player_id = v_player.id)
      )
    );
  end if;

  return v_result;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- host_get_state: liefert zusätzlich die Art der Frage. Antworten bleiben
-- aggregiert (Anzahl pro Antwort, Anzahl der Personen mit Antwort); einzelne
-- Antworten von Personen werden nicht ausgegeben.
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
    -- was als Nächstes kommt (für den Weiter-Knopf und zum Vorladen der Bilder)
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
      'question_number', (select count(*) from public.questions q
                          where q.quiz_id = v_q.quiz_id and q.kind = 'question'
                            and (q.position, q.id) <= (v_q.position, v_q.id)));

    if v_q.kind = 'slide' then
      v_result := v_result || jsonb_build_object(
        'slide', jsonb_build_object(
          'id', v_q.id,
          'heading', v_q.heading,
          'text', v_q.text,
          'images', to_jsonb(v_q.image_paths)));
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
-- host_save_quiz: Art poll, Punkte bei Umfragen immer 0, bis zu 6 Bilder
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
    if v_kind not in ('question', 'poll', 'slide') then
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

    if v_kind = 'slide' then
      if char_length(v_text) > 1000 or char_length(btrim(coalesce(v_q->>'heading', ''))) > 200 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_SLIDE', 'question', v_qpos);
      end if;
      -- eine Slide hat nie Antworten
      if jsonb_typeof(v_q->'options') = 'array' and jsonb_array_length(v_q->'options') > 0 then
        return jsonb_build_object('ok', false, 'error', 'INVALID_SLIDE', 'question', v_qpos);
      end if;
      -- und braucht irgendeinen Inhalt
      if v_text = '' and btrim(coalesce(v_q->>'heading', '')) = ''
         and coalesce(jsonb_array_length(nullif(v_q->'images', 'null'::jsonb)), 0) = 0 then
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

    select coalesce(array_agg(t.p), '{}'::text[]) into v_before
    from public.questions q, unnest(q.image_paths) as t (p)
    where q.quiz_id = v_quiz_id;

    update public.quizzes z set title = v_title, updated_at = now() where z.id = v_quiz_id;
  end if;

  for v_q, v_qpos in
    select t.value, t.ordinality from jsonb_array_elements(v_items) with ordinality as t
  loop
    v_kind := coalesce(v_q->>'kind', 'question');
    v_text := btrim(coalesce(v_q->>'text', ''));
    v_heading := case when v_kind = 'slide' then nullif(btrim(coalesce(v_q->>'heading', '')), '') end;
    select coalesce(array_agg(t.value order by t.ordinality), '{}'::text[]) into v_images
    from jsonb_array_elements_text(
           case when jsonb_typeof(v_q->'images') = 'array' then v_q->'images' else '[]'::jsonb end
         ) with ordinality as t;

    v_qid := nullif(v_q->>'id', '')::uuid;
    if v_qid is not null then
      update public.questions q
      set position = v_qpos, kind = v_kind, text = v_text, heading = v_heading, image_paths = v_images,
          max_selections = case when v_kind = 'slide' then 1 else (v_q->>'max_selections')::int end
      where q.id = v_qid and q.quiz_id = v_quiz_id;
      if not found then v_qid := null; end if;
    end if;
    if v_qid is null then
      insert into public.questions (quiz_id, position, kind, text, heading, image_paths, max_selections)
      values (v_quiz_id, v_qpos, v_kind, v_text, v_heading, v_images,
              case when v_kind = 'slide' then 1 else (v_q->>'max_selections')::int end)
      returning id into v_qid;
    end if;
    v_keep_q := v_keep_q || v_qid;

    v_keep_o := '{}';
    if v_kind <> 'slide' then
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

    -- bei Slides bleibt v_keep_o leer: alle Antworten werden entfernt
    delete from public.answer_options o where o.question_id = v_qid and o.id <> all (v_keep_o);
  end loop;

  delete from public.questions q where q.quiz_id = v_quiz_id and q.id <> all (v_keep_q);

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
