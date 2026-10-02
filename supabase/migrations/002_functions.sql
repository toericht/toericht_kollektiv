-- töricht live – Phase 2: Funktionen
-- Im Supabase SQL Editor ausführen (nach 001_schema.sql). Kann wiederholt ausgeführt werden.
--
-- Konvention: Alle Funktionen geben jsonb zurück,
--   { "ok": true, ... }  oder  { "ok": false, "error": "CODE" }.
-- Fehler werden nicht als Exception geworfen, damit z. B. Fehlversuchs-Zähler
-- nicht durch ein Rollback verloren gehen.

-- ---------------------------------------------------------------------------
-- Interne Helfer (Schema private ist nicht über die API erreichbar)
-- ---------------------------------------------------------------------------

create or replace function private.hash_secret(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p, 'UTF8')), 'hex');
$$;

-- Zufallscode aus 32 nicht verwechselbaren Zeichen (kein I, O, 0, 1).
-- gen_random_uuid() nutzt den kryptografischen Zufallsgenerator von Postgres;
-- Byte 0 einer v4-UUID ist vollständig zufällig.
create or replace function private.random_code(p_len int)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text := '';
begin
  for i in 1..p_len loop
    v_code := v_code || substr(c_alphabet, 1 + (get_byte(uuid_send(gen_random_uuid()), 0) & 31), 1);
  end loop;
  return v_code;
end;
$$;

-- Score ist immer die Summe der gespeicherten Antwortpunkte, nie ein Zähler.
-- Doppelte Nicknames werden nach Beitrittsreihenfolge als "Name (2)" angezeigt.
create or replace function private.session_scores(p_session_id uuid)
returns table (
  player_id    uuid,
  display_name text,
  score        bigint,
  rank         bigint,
  joined_at    timestamptz,
  last_seen_at timestamptz,
  removed      boolean
)
language sql
stable
set search_path = ''
as $$
  with named as (
    select p.id, p.nickname, p.joined_at, p.last_seen_at, p.removed,
           row_number() over (partition by lower(p.nickname) order by p.joined_at, p.id) as n
    from public.players p
    where p.session_id = p_session_id
  ),
  scored as (
    select n.*,
           coalesce((select sum(a.points_awarded) from public.player_answers a where a.player_id = n.id), 0)::bigint as total
    from named n
  )
  select s.id,
         case when s.n > 1 then s.nickname || ' (' || s.n || ')' else s.nickname end,
         s.total,
         rank() over (partition by s.removed order by s.total desc),
         s.joined_at,
         s.last_seen_at,
         s.removed
  from scored s;
$$;

-- Realtime-Signal "Stand hat sich geändert". Enthält nur die Versionsnummer.
-- Darf niemals einen Zustandswechsel verhindern, deshalb werden Fehler geschluckt.
create or replace function private.notify_session(p_session_id uuid, p_version int)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object('version', p_version),
    'state',
    'game:' || p_session_id::text,
    false
  );
exception when others then
  null;
end;
$$;

revoke all on function private.hash_secret(text) from public;
revoke all on function private.random_code(int) from public;
revoke all on function private.session_scores(uuid) from public;
revoke all on function private.notify_session(uuid, int) from public;

-- ---------------------------------------------------------------------------
-- Spieler:innen
-- ---------------------------------------------------------------------------

-- Beitritt. Das Token erzeugt der Client vorab und speichert es lokal; dadurch
-- ist ein wiederholter Request (Doppelklick, Retry) idempotent.
create or replace function public.join_game(p_join_code text, p_nickname text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code    text := upper(regexp_replace(coalesce(p_join_code, ''), '\s', '', 'g'));
  v_nick    text := btrim(regexp_replace(coalesce(p_nickname, ''), '\s+', ' ', 'g'));
  v_hash    text;
  v_session public.game_sessions;
  v_player  public.players;
begin
  if p_token is null or char_length(p_token) not between 32 and 200 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN');
  end if;
  if char_length(v_nick) not between 1 and 24 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_NICKNAME');
  end if;

  select * into v_session from public.game_sessions s where s.join_code = v_code for share;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
  end if;

  v_hash := private.hash_secret(p_token);

  select * into v_player from public.players p where p.token_hash = v_hash;
  if found then
    if v_player.session_id <> v_session.id then
      return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN');
    end if;
    return jsonb_build_object('ok', true, 'player_id', v_player.id,
                              'session_id', v_session.id, 'nickname', v_player.nickname);
  end if;

  if v_session.state = 'ENDED' then
    return jsonb_build_object('ok', false, 'error', 'SESSION_ENDED');
  end if;
  if v_session.join_locked then
    return jsonb_build_object('ok', false, 'error', 'JOIN_LOCKED');
  end if;
  if (select count(*) from public.players p where p.session_id = v_session.id) >= 300 then
    return jsonb_build_object('ok', false, 'error', 'SESSION_FULL');
  end if;

  insert into public.players (session_id, nickname, token_hash)
  values (v_session.id, v_nick, v_hash)
  on conflict (token_hash) do nothing
  returning * into v_player;

  if v_player.id is null then
    -- derselbe Request kam parallel doppelt an
    select * into v_player from public.players p where p.token_hash = v_hash;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_player.id,
                            'session_id', v_session.id, 'nickname', v_player.nickname);
end;
$$;

-- Vollständiger Stand für eine Person. Liefert nur, was im aktuellen Zustand
-- sichtbar sein darf: nie Punktwerte, nie zukünftige Fragen, Scores erst ab
-- LEADERBOARD.
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
    v_result := v_result || jsonb_build_object(
      'leaderboard', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'rank', t.rank, 'name', t.display_name, 'score', t.score,
                 'me', t.player_id = v_player.id
               ) order by t.rank, t.joined_at), '[]'::jsonb)
        from (select s.* from private.session_scores(v_session.id) s
              where not s.removed
              order by s.rank, s.joined_at
              limit 10) t),
      'me', (select jsonb_build_object('rank', s.rank, 'name', s.display_name, 'score', s.score)
             from private.session_scores(v_session.id) s
             where s.player_id = v_player.id)
    );
  end if;

  return v_result;
end;
$$;

-- Antwort abgeben oder ändern. Der Client schickt nur IDs, nie Punkte.
-- Die Lesesperre auf der Session-Zeile bringt diese Funktion und das Schließen
-- durch den Host (UPDATE derselben Zeile) in eine eindeutige Reihenfolge.
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
    (session_id, player_id, question_id, option_ids, points_awarded, client_seq)
  values
    (v_player.session_id, v_player.id, p_question_id, v_ids, v_points, v_seq)
  on conflict (player_id, question_id) do update
    set option_ids     = excluded.option_ids,
        points_awarded = excluded.points_awarded,
        client_seq     = excluded.client_seq,
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

-- Recovery-Code einlösen. Der Client erzeugt dafür immer ein neues Token;
-- das alte Token der Person wird ungültig.
create or replace function public.recover_player(p_join_code text, p_code text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_join_code  text := upper(regexp_replace(coalesce(p_join_code, ''), '\s', '', 'g'));
  v_code_hash  text := private.hash_secret(upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')));
  v_token_hash text;
  v_session    public.game_sessions;
  v_player     public.players;
  v_player_id  uuid;
  v_failures   int;
begin
  if p_token is null or char_length(p_token) not between 32 and 200 then
    return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN');
  end if;
  v_token_hash := private.hash_secret(p_token);

  select * into v_session from public.game_sessions s where s.join_code = v_join_code for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
  end if;

  select * into v_player from public.players p where p.token_hash = v_token_hash;
  if found then
    -- Wiederholung eines bereits erfolgreichen Recovery-Requests
    if exists (select 1 from public.recovery_codes c
               where c.session_id = v_session.id
                 and c.code_hash = v_code_hash
                 and c.player_id = v_player.id
                 and c.used_at is not null) then
      return jsonb_build_object('ok', true, 'player_id', v_player.id,
                                'session_id', v_session.id, 'nickname', v_player.nickname);
    end if;
    return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN');
  end if;

  update public.recovery_codes c set used_at = now()
  where c.id = (select c2.id from public.recovery_codes c2
                where c2.session_id = v_session.id
                  and c2.code_hash = v_code_hash
                  and c2.used_at is null
                  and c2.expires_at > now()
                order by c2.created_at desc
                limit 1)
  returning c.player_id into v_player_id;

  if v_player_id is null then
    update public.game_sessions s set recovery_failures = s.recovery_failures + 1
    where s.id = v_session.id
    returning s.recovery_failures into v_failures;

    if v_failures >= 10 then
      update public.recovery_codes c set expires_at = now()
      where c.session_id = v_session.id and c.used_at is null and c.expires_at > now();
      update public.game_sessions s set recovery_failures = 0 where s.id = v_session.id;
    end if;

    return jsonb_build_object('ok', false, 'error', 'INVALID_CODE');
  end if;

  update public.players p set token_hash = v_token_hash, last_seen_at = now()
  where p.id = v_player_id
  returning * into v_player;

  return jsonb_build_object('ok', true, 'player_id', v_player.id,
                            'session_id', v_session.id, 'nickname', v_player.nickname);
end;
$$;

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

create or replace function public.host_create_session(p_quiz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.game_sessions;
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;
  if not exists (select 1 from public.quizzes z where z.id = p_quiz_id) then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_NOT_FOUND');
  end if;
  if not exists (select 1 from public.questions q where q.quiz_id = p_quiz_id) then
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
$$;

-- Zustandswechsel. p_expected_version verhindert, dass Doppelklicks oder ein
-- zweiter Host-Tab einen Schritt doppelt ausführen.
-- Aktionen: OPEN_NEXT, CLOSE, REOPEN, SHOW_RESULTS, SHOW_LEADERBOARD, SHOW_FINAL, END
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

-- Vollständiger Stand für Host und Presenter, inklusive Punktwerten.
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

create or replace function public.host_set_join_locked(p_session_id uuid, p_locked boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  update public.game_sessions s set join_locked = coalesce(p_locked, false) where s.id = p_session_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'SESSION_NOT_FOUND');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.host_set_player_removed(p_player_id uuid, p_removed boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  update public.players p set removed = coalesce(p_removed, true) where p.id = p_player_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'PLAYER_NOT_FOUND');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Einmal-Code für genau eine Person: 6 Zeichen, 3 Minuten gültig, nur als Hash
-- gespeichert. Ein neuer Code macht ältere Codes derselben Person ungültig.
create or replace function public.host_create_recovery_code(p_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player  public.players;
  v_code    text;
  v_expires timestamptz := now() + interval '3 minutes';
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;

  select * into v_player from public.players p where p.id = p_player_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'PLAYER_NOT_FOUND');
  end if;

  update public.recovery_codes c set expires_at = now()
  where c.player_id = v_player.id and c.used_at is null and c.expires_at > now();

  v_code := private.random_code(6);

  insert into public.recovery_codes (session_id, player_id, code_hash, expires_at)
  values (v_player.session_id, v_player.id, private.hash_secret(v_code), v_expires);

  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_expires);
end;
$$;

-- ---------------------------------------------------------------------------
-- Ausführungsrechte
-- ---------------------------------------------------------------------------

revoke all on function public.join_game(text, text, text) from public;
revoke all on function public.get_state(text) from public;
revoke all on function public.submit_answer(text, uuid, uuid[], bigint) from public;
revoke all on function public.recover_player(text, text, text) from public;

grant execute on function public.join_game(text, text, text) to anon, authenticated;
grant execute on function public.get_state(text) to anon, authenticated;
grant execute on function public.submit_answer(text, uuid, uuid[], bigint) to anon, authenticated;
grant execute on function public.recover_player(text, text, text) to anon, authenticated;

revoke all on function public.host_create_session(uuid) from public, anon;
revoke all on function public.host_action(uuid, int, text) from public, anon;
revoke all on function public.host_get_state(uuid) from public, anon;
revoke all on function public.host_set_join_locked(uuid, boolean) from public, anon;
revoke all on function public.host_set_player_removed(uuid, boolean) from public, anon;
revoke all on function public.host_create_recovery_code(uuid) from public, anon;

grant execute on function public.host_create_session(uuid) to authenticated;
grant execute on function public.host_action(uuid, int, text) to authenticated;
grant execute on function public.host_get_state(uuid) to authenticated;
grant execute on function public.host_set_join_locked(uuid, boolean) to authenticated;
grant execute on function public.host_set_player_removed(uuid, boolean) to authenticated;
grant execute on function public.host_create_recovery_code(uuid) to authenticated;
