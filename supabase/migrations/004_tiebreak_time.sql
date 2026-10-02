-- töricht live – Zeit als Tie-Breaker
-- Im Supabase SQL Editor ausführen (nach 001–003). Kann wiederholt ausgeführt werden.
--
-- Regeln:
--   * Ranking: Gesamtpunkte absteigend, bei Gleichstand kumulierte Antwortzeit aufsteigend.
--   * Antwortzeit pro Frage = Zeit, die die Frage bis zur zuletzt gültig gespeicherten
--     Antwort OFFEN war. Gemessen wird ausschließlich mit der Serveruhr.
--   * Eine geänderte Antwort ersetzt auch die Antwortzeit.
--   * REOPEN: Die Uhr läuft dort weiter, wo sie beim Schließen stehen geblieben ist.
--     Die Pause zwischen Schließen und Wiederöffnen zählt für niemanden.
--   * Nicht beantwortete Fragen zählen mit der vollen Öffnungsdauer der Frage,
--     damit Nicht-Antworten nie ein Zeitvorteil ist.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- Pro Session und Frage: wie lange war die Frage bisher offen?
create table if not exists public.session_questions (
  session_id      uuid not null references public.game_sessions (id) on delete cascade,
  question_id     uuid not null references public.questions (id),
  -- Summe aller abgeschlossenen Öffnungsphasen in Millisekunden
  open_ms         bigint not null default 0,
  -- Beginn der laufenden Öffnungsphase; null, solange die Frage geschlossen ist
  last_opened_at  timestamptz,
  first_opened_at timestamptz not null default now(),
  primary key (session_id, question_id)
);

alter table public.session_questions enable row level security;
revoke all on table public.session_questions from anon, authenticated;

alter table public.player_answers
  add column if not exists answer_ms bigint not null default 0;

-- ---------------------------------------------------------------------------
-- Scores inklusive Antwortzeit
-- ---------------------------------------------------------------------------

drop function if exists private.session_scores(uuid);

create function private.session_scores(p_session_id uuid)
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
as $$
  with sq as (
    select q.question_id,
           q.open_ms + case
             when q.last_opened_at is null then 0
             else greatest((extract(epoch from (clock_timestamp() - q.last_opened_at)) * 1000)::bigint, 0)
           end as duration_ms
    from public.session_questions q
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
$$;

revoke all on function private.session_scores(uuid) from public;

-- ---------------------------------------------------------------------------
-- submit_answer: misst die Antwortzeit mit der Serveruhr
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
as $$
declare
  v_player  public.players;
  v_state   public.game_state;
  v_current uuid;
  v_version int;
  v_ids     uuid[];
  v_max     int;
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

  select q.max_selections into v_max from public.questions q where q.id = p_question_id;

  if cardinality(v_ids) < 1 or cardinality(v_ids) > v_max then
    return jsonb_build_object('ok', false, 'error', 'INVALID_SELECTION');
  end if;

  select count(*)::int, coalesce(sum(o.points), 0)::int into v_valid, v_points
  from public.answer_options o
  where o.question_id = p_question_id and o.id = any (v_ids);

  if v_valid <> cardinality(v_ids) then
    return jsonb_build_object('ok', false, 'error', 'INVALID_SELECTION');
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
$$;

-- ---------------------------------------------------------------------------
-- host_action: führt die Öffnungsdauer jeder Frage mit
-- ---------------------------------------------------------------------------

create or replace function public.host_action(p_session_id uuid, p_expected_version int, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s         public.game_sessions;
  v_new_state public.game_state;
  v_new_q     uuid;
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

  case p_action
    when 'OPEN_NEXT' then
      if v_s.state not in ('LOBBY', 'QUESTION_CLOSED', 'RESULTS', 'LEADERBOARD') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      if v_s.current_question_id is null then
        select q.id into v_new_q from public.questions q
        where q.quiz_id = v_s.quiz_id
        order by q.position, q.id
        limit 1;
      else
        select q.id into v_new_q
        from public.questions q
        join public.questions c on c.id = v_s.current_question_id
        where q.quiz_id = v_s.quiz_id and (q.position, q.id) > (c.position, c.id)
        order by q.position, q.id
        limit 1;
      end if;
      if v_new_q is null then
        return jsonb_build_object('ok', false, 'error', 'NO_MORE_QUESTIONS');
      end if;
      v_new_state := 'QUESTION_OPEN';

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
      if v_s.state not in ('QUESTION_CLOSED', 'LEADERBOARD') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'RESULTS';

    when 'SHOW_LEADERBOARD' then
      if v_s.state not in ('QUESTION_CLOSED', 'RESULTS') then
        return jsonb_build_object('ok', false, 'error', 'INVALID_TRANSITION', 'state', v_s.state);
      end if;
      v_new_state := 'LEADERBOARD';

    when 'SHOW_FINAL' then
      if v_s.state not in ('QUESTION_CLOSED', 'RESULTS', 'LEADERBOARD') then
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

  -- Öffnungsdauer mitführen
  if v_s.state = 'QUESTION_OPEN' and v_new_state <> 'QUESTION_OPEN' then
    -- Frage wird geschlossen (CLOSE oder END): laufende Phase abschließen
    update public.session_questions sq
    set open_ms = sq.open_ms
                  + greatest((extract(epoch from (v_now - sq.last_opened_at)) * 1000)::bigint, 0),
        last_opened_at = null
    where sq.session_id = v_s.id
      and sq.question_id = v_s.current_question_id
      and sq.last_opened_at is not null;
  elsif p_action = 'OPEN_NEXT' then
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
$$;

-- ---------------------------------------------------------------------------
-- get_state: Rangliste mit Antwortzeit
-- ---------------------------------------------------------------------------

create or replace function public.get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player  public.players;
  v_session public.game_sessions;
  v_q       public.questions;
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

  if v_session.state in ('QUESTION_OPEN', 'QUESTION_CLOSED', 'RESULTS')
     and v_session.current_question_id is not null then
    select * into v_q from public.questions q where q.id = v_session.current_question_id;

    v_result := v_result || jsonb_build_object(
      'question', jsonb_build_object(
        'id', v_q.id,
        'text', v_q.text,
        'max_selections', v_q.max_selections,
        'number', (select count(*) from public.questions q
                   where q.quiz_id = v_q.quiz_id and (q.position, q.id) <= (v_q.position, v_q.id)),
        'total', (select count(*) from public.questions q where q.quiz_id = v_q.quiz_id),
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
      v_result := v_result || jsonb_build_object(
        'results', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'option_id', o.id,
                   'count', (select count(*)
                             from public.player_answers a
                             join public.players p on p.id = a.player_id
                             where a.session_id = v_session.id
                               and a.question_id = v_q.id
                               and not p.removed
                               and o.id = any (a.option_ids))
                 ) order by o.position, o.id), '[]'::jsonb)
          from public.answer_options o where o.question_id = v_q.id)
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
$$;

-- ---------------------------------------------------------------------------
-- host_get_state: Rangliste mit Antwortzeit
-- ---------------------------------------------------------------------------

create or replace function public.host_get_state(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s      public.game_sessions;
  v_q      public.questions;
  v_result jsonb;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  select * into v_s from public.game_sessions s where s.id = p_session_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
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
    'question_total', (select count(*) from public.questions q where q.quiz_id = v_s.quiz_id),
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

  if v_s.current_question_id is not null then
    select * into v_q from public.questions q where q.id = v_s.current_question_id;

    v_result := v_result || jsonb_build_object(
      'question_number', (select count(*) from public.questions q
                          where q.quiz_id = v_q.quiz_id and (q.position, q.id) <= (v_q.position, v_q.id)),
      'answered_count', (select count(*)
                         from public.player_answers a
                         join public.players p on p.id = a.player_id
                         where a.session_id = v_s.id and a.question_id = v_q.id and not p.removed),
      'question', jsonb_build_object(
        'id', v_q.id,
        'text', v_q.text,
        'max_selections', v_q.max_selections,
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

  return v_result;
end;
$$;
