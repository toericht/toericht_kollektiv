-- töricht live – Presenter-Slides und Bilder
-- Im Supabase SQL Editor ausführen (nach 001–007). Kann wiederholt ausgeführt werden.
--
-- * Fragen und Slides liegen gemeinsam in public.questions (Spalte kind) und
--   teilen sich die Reihenfolge über position.
-- * Slides haben keine Antworten, nehmen keine Antworten an und bekommen keinen
--   Zeiteintrag in session_questions – sie können Punkte, Antwortzeiten und
--   Tie-Breaker deshalb nicht beeinflussen.
-- * Bilder liegen in Supabase Storage (Bucket quiz-images). Pro Bild gibt es
--   zwei Dateien: <uuid>.<ext> (groß, Presenter) und <uuid>_m.<ext> (klein, Handy).
--   In der Datenbank steht nur der Name der großen Datei.
-- * Enthält außerdem die Farbstufen und eigenen Punkte aus 006.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

alter table public.questions
  add column if not exists kind text not null default 'question'
    check (kind in ('question', 'slide'));

alter table public.questions
  add column if not exists heading text
    check (heading is null or char_length(heading) <= 200);

alter table public.questions
  add column if not exists image_paths text[] not null default '{}'
    check (cardinality(image_paths) <= 2);

-- Fragen brauchen weiterhin einen Text; bei Slides ist er optional.
alter table public.questions drop constraint if exists questions_text_check;
alter table public.questions add constraint questions_text_check
  check (char_length(text) <= 1000 and (kind = 'slide' or char_length(text) >= 1));

-- ---------------------------------------------------------------------------
-- Storage: öffentlicher Bucket mit nicht erratbaren Dateinamen.
-- Lesen per Adresse kann jede:r, auflisten niemand außer Hosts;
-- hochladen, ersetzen und löschen nur Hosts.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('quiz-images', 'quiz-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists quiz_images_host_select on storage.objects;
drop policy if exists quiz_images_host_insert on storage.objects;
drop policy if exists quiz_images_host_update on storage.objects;
drop policy if exists quiz_images_host_delete on storage.objects;

create policy quiz_images_host_select on storage.objects
  for select to authenticated
  using (bucket_id = 'quiz-images' and (select public.is_host()));

create policy quiz_images_host_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'quiz-images' and (select public.is_host()));

create policy quiz_images_host_update on storage.objects
  for update to authenticated
  using (bucket_id = 'quiz-images' and (select public.is_host()))
  with check (bucket_id = 'quiz-images' and (select public.is_host()));

create policy quiz_images_host_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'quiz-images' and (select public.is_host()));

-- ---------------------------------------------------------------------------
-- host_create_session: ein Quiz braucht mindestens eine Frage
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
  if not exists (select 1 from public.questions q where q.quiz_id = p_quiz_id and q.kind = 'question') then
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
-- submit_answer: unverändert, plus Absicherung "das Ziel ist eine Frage"
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
  if v_kind is distinct from 'question' then
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
-- host_action: "weiter" führt je nach nächstem Eintrag zu einer Frage oder Slide
-- Aktionen: OPEN_NEXT, CLOSE, REOPEN, SHOW_RESULTS, SHOW_LEADERBOARD, SHOW_FINAL, END
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
-- get_state: bei SLIDE nur der Zustand, kein Inhalt. Fragen mit Handy-Bildern.
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
        'text', v_q.text,
        'max_selections', v_q.max_selections,
        -- gezählt werden nur Fragen, keine Slides
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
        -- eigene Punkte für diese Frage; null, wenn die Person nicht geantwortet hat
        'my_question_score', (select a.points_awarded from public.player_answers a
                              where a.player_id = v_player.id and a.question_id = v_q.id),
        'results', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'option_id', o.id,
                   'tier', case
                             when o.points > 0 and o.points = v_max then 'best'
                             when o.points > 0 then 'good'
                             else 'bad'
                           end,
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
$fn$;

-- ---------------------------------------------------------------------------
-- host_get_state: aktuelle Frage oder Slide, Bilder und der nächste Eintrag
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
-- Bilder, die kein Quiz mehr verwendet (zum Aufräumen im Storage)
-- ---------------------------------------------------------------------------

create or replace function private.unused_images(p_paths text[])
returns text[]
language sql
stable
set search_path = ''
as $fn$
  select coalesce(array_agg(distinct t.p), '{}'::text[])
  from unnest(p_paths) as t (p)
  where not exists (select 1 from public.questions q where t.p = any (q.image_paths));
$fn$;

revoke all on function private.unused_images(text[]) from public;

-- ---------------------------------------------------------------------------
-- host_save_quiz: Fragen und Slides in gemeinsamer Reihenfolge, mit Bildern
-- ---------------------------------------------------------------------------
--
-- p_quiz: {
--   "id": "<uuid>" | null,
--   "title": "...",
--   "items": [
--     { "id": ..., "kind": "question", "text": "...", "max_selections": 1,
--       "images": ["<uuid>.webp"],
--       "options": [ { "id": ..., "label": "...", "points": 5 } ] },
--     { "id": ..., "kind": "slide", "heading": "...", "text": "...", "images": [] }
--   ]
-- }
-- Das ältere Format mit "questions" statt "items" wird weiter angenommen; dort
-- ist jeder Eintrag eine Frage.
-- Rückgabe enthält removed_images: Dateien, die danach kein Quiz mehr verwendet.
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
    if v_kind not in ('question', 'slide') then
      return jsonb_build_object('ok', false, 'error', 'INVALID_ITEM', 'question', v_qpos);
    end if;

    if v_q ? 'images' and jsonb_typeof(v_q->'images') <> 'null' then
      if jsonb_typeof(v_q->'images') <> 'array' or jsonb_array_length(v_q->'images') > 2
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
        if coalesce(v_o->>'points', '') !~ '^-?\d{1,6}$' then
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
    if v_kind = 'question' then
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

-- ---------------------------------------------------------------------------
-- host_delete_quiz: gibt die danach unbenutzten Bilder zurück
-- ---------------------------------------------------------------------------

create or replace function public.host_delete_quiz(p_quiz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_before text[];
begin
  if not public.is_host() then
    return jsonb_build_object('ok', false, 'error', 'NOT_HOST');
  end if;
  if exists (select 1 from public.game_sessions s where s.quiz_id = p_quiz_id) then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_HAS_SESSIONS');
  end if;

  select coalesce(array_agg(t.p), '{}'::text[]) into v_before
  from public.questions q, unnest(q.image_paths) as t (p)
  where q.quiz_id = p_quiz_id;

  delete from public.quizzes z where z.id = p_quiz_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_NOT_FOUND');
  end if;

  return jsonb_build_object('ok', true, 'removed_images', to_jsonb(private.unused_images(v_before)));
end;
$fn$;
