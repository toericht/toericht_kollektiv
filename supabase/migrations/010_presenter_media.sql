-- töricht live – Medien nur auf dem Presenter: Video, Audio, Punkte in der Auflösung
-- Im Supabase SQL Editor ausführen (nach 001–009). Kann wiederholt ausgeführt werden.
--
-- * Spieler:innen bekommen keine Medien mehr: get_state liefert weder Bild- noch
--   Video- noch Audio-Pfade. Das Handy ist nur noch Controller.
-- * Neue Funktion presenter_get_state für den Beamer. Sie liefert nur, was im
--   jeweiligen Zustand gezeigt wird: Punktwerte und Stimmen erst in RESULTS,
--   die Rangliste erst in LEADERBOARD/FINAL_RESULTS/ENDED, nie einzelne Antworten.
-- * Neue Spalte questions.media (jsonb) für Video, Audio und die Beschriftung
--   der Bilder:
--     { "video": { "path": "<uuid>.mp4", "loop": true },
--       "audio": [ { "path": "<uuid>.mp3", "loop": false, "volume": 0.8 } ],
--       "image_labels": true }
--   Slides: höchstens ein Sound (läuft automatisch). Fragen/Umfragen: bis zu
--   sechs Clips (A, B, C …, werden von Hand gestartet).
-- * Punkte-, Zeit-, Antwort- und Recovery-Logik bleiben unverändert;
--   submit_answer, host_action und session_scores werden nicht angefasst.

-- ---------------------------------------------------------------------------
-- Schema und Storage
-- ---------------------------------------------------------------------------

alter table public.questions
  add column if not exists media jsonb not null default '{}'::jsonb;

-- Der Bucket heißt weiter quiz-images, nimmt jetzt aber auch Video und Audio an.
-- Hochladen, Ersetzen und Löschen bleibt Hosts vorbehalten (Regeln aus 008).
update storage.buckets
set file_size_limit = 52428800,
    allowed_mime_types = array[
      'image/jpeg', 'image/png', 'image/webp',
      'video/mp4', 'video/webm',
      'audio/mpeg', 'audio/mp4', 'audio/wav', 'audio/ogg'
    ]
where id = 'quiz-images';

-- ---------------------------------------------------------------------------
-- Medien-Angaben prüfen und vereinheitlichen. Gibt null zurück, wenn ungültig.
-- ---------------------------------------------------------------------------

create or replace function private.clean_media(p_media jsonb, p_kind text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  c_uuid  constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.';
  v_out   jsonb := '{}'::jsonb;
  v_video jsonb;
  v_audio jsonb;
  v_a     jsonb;
  v_list  jsonb := '[]'::jsonb;
  v_vol   numeric;
begin
  if p_media is null or jsonb_typeof(p_media) = 'null' then
    return '{}'::jsonb;
  end if;
  if jsonb_typeof(p_media) <> 'object' then
    return null;
  end if;

  v_video := p_media->'video';
  if v_video is not null and jsonb_typeof(v_video) <> 'null' then
    if jsonb_typeof(v_video) <> 'object' then
      return null;
    end if;
    if jsonb_typeof(v_video->'path') is distinct from 'string'
       or (v_video->>'path') !~ (c_uuid || '(mp4|webm)$') then
      return null;
    end if;
    v_out := v_out || jsonb_build_object('video', jsonb_build_object(
      'path', v_video->>'path',
      'loop', coalesce(v_video->'loop' = 'true'::jsonb, false)));
  end if;

  v_audio := p_media->'audio';
  if v_audio is not null and jsonb_typeof(v_audio) <> 'null' then
    if jsonb_typeof(v_audio) <> 'array' then
      return null;
    end if;
    if jsonb_array_length(v_audio) > (case when p_kind = 'slide' then 1 else 6 end) then
      return null;
    end if;
    for v_a in select t.value from jsonb_array_elements(v_audio) as t loop
      if jsonb_typeof(v_a) <> 'object' then
        return null;
      end if;
      if jsonb_typeof(v_a->'path') is distinct from 'string'
         or (v_a->>'path') !~ (c_uuid || '(mp3|m4a|wav|ogg)$') then
        return null;
      end if;
      v_vol := 1;
      if v_a ? 'volume' and jsonb_typeof(v_a->'volume') <> 'null' then
        if jsonb_typeof(v_a->'volume') <> 'number' then
          return null;
        end if;
        v_vol := (v_a->>'volume')::numeric;
        if v_vol < 0 or v_vol > 1 then
          return null;
        end if;
      end if;
      v_list := v_list || jsonb_build_array(jsonb_build_object(
        'path', v_a->>'path',
        'loop', coalesce(v_a->'loop' = 'true'::jsonb, false),
        'volume', v_vol));
    end loop;
    if jsonb_array_length(v_list) > 0 then
      v_out := v_out || jsonb_build_object('audio', v_list);
    end if;
  end if;

  -- Bilder auf dem Presenter mit A, B, C beschriften (nur bei Fragen/Umfragen)
  if p_kind <> 'slide' and p_media->'image_labels' = 'true'::jsonb then
    v_out := v_out || jsonb_build_object('image_labels', true);
  end if;

  return v_out;
end;
$fn$;

-- Alle Dateien eines Quiz (Bilder, Video, Audio)
create or replace function private.quiz_files(p_quiz_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $fn$
  select coalesce(array_agg(f.path), '{}'::text[])
  from (
    select t.p as path
    from public.questions q, unnest(q.image_paths) as t (p)
    where q.quiz_id = p_quiz_id
    union all
    select q.media->'video'->>'path'
    from public.questions q
    where q.quiz_id = p_quiz_id
    union all
    select a.value->>'path'
    from public.questions q,
         jsonb_array_elements(case when jsonb_typeof(q.media->'audio') = 'array'
                                   then q.media->'audio' else '[]'::jsonb end) as a
    where q.quiz_id = p_quiz_id
  ) f
  where f.path is not null;
$fn$;

-- Dateien, die kein Quiz mehr verwendet (zum Aufräumen im Storage)
create or replace function private.unused_images(p_paths text[])
returns text[]
language sql
stable
set search_path = ''
as $fn$
  select coalesce(array_agg(distinct t.p), '{}'::text[])
  from unnest(p_paths) as t (p)
  where not exists (
    select 1 from public.questions q
    where t.p = any (q.image_paths)
       or q.media->'video'->>'path' = t.p
       or exists (select 1
                  from jsonb_array_elements(case when jsonb_typeof(q.media->'audio') = 'array'
                                                 then q.media->'audio' else '[]'::jsonb end) as a
                  where a.value->>'path' = t.p));
$fn$;

revoke all on function private.clean_media(jsonb, text) from public;
revoke all on function private.quiz_files(uuid) from public;
revoke all on function private.unused_images(text[]) from public;

-- ---------------------------------------------------------------------------
-- get_state: keine Medien mehr für Spieler:innen
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
  -- Bilder, Video und Audio laufen nur auf dem Presenter und werden hier nie ausgegeben.
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
-- presenter_get_state: nur das, was der Beamer im aktuellen Zustand zeigt
-- ---------------------------------------------------------------------------

create or replace function public.presenter_get_state(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_s       public.game_sessions;
  v_q       public.questions;
  v_next    public.questions;
  v_reveal  boolean;
  v_result  jsonb;
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
      'version', v_s.version
    ),
    'player_count', (select count(*) from public.players p
                     where p.session_id = v_s.id and not p.removed),
    'question_total', (select count(*) from public.questions q
                       where q.quiz_id = v_s.quiz_id and q.kind = 'question'),
    -- nur die Bilder des nächsten Eintrags, zum Vorladen
    'next', case when v_next.id is null then null
                 else jsonb_build_object('images', to_jsonb(v_next.image_paths)) end
  );

  if v_s.state = 'SLIDE' and v_q.id is not null then
    v_result := v_result || jsonb_build_object(
      'slide', jsonb_build_object(
        'id', v_q.id,
        'heading', v_q.heading,
        'text', v_q.text,
        'images', to_jsonb(v_q.image_paths),
        'media', v_q.media));
  end if;

  if v_s.state in ('QUESTION_OPEN', 'QUESTION_CLOSED', 'RESULTS') and v_q.id is not null then
    -- Punktwerte und Stimmen gibt es erst in der Auflösung
    v_reveal := v_s.state = 'RESULTS';

    v_result := v_result || jsonb_build_object(
      'question_number', (select count(*) from public.questions q
                          where q.quiz_id = v_q.quiz_id and q.kind = 'question'
                            and (q.position, q.id) <= (v_q.position, v_q.id)),
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
          select coalesce(jsonb_agg(
                   jsonb_build_object('label', o.label)
                   || case when v_reveal then jsonb_build_object(
                        'count', (select count(*)
                                  from public.player_answers a
                                  join public.players p on p.id = a.player_id
                                  where a.session_id = v_s.id
                                    and a.question_id = v_q.id
                                    and not p.removed
                                    and o.id = any (a.option_ids)))
                      else '{}'::jsonb end
                   -- Punkte nur bei gewerteten Fragen, nie bei Umfragen
                   || case when v_reveal and v_q.kind = 'question'
                           then jsonb_build_object('points', o.points)
                           else '{}'::jsonb end
                   order by o.position, o.id), '[]'::jsonb)
          from public.answer_options o where o.question_id = v_q.id)
      )
    );
  end if;

  if v_s.state in ('LEADERBOARD', 'FINAL_RESULTS', 'ENDED') then
    v_result := v_result || jsonb_build_object(
      'leaderboard', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'rank', t.rank, 'name', t.display_name, 'score', t.score,
                 'time_ms', t.time_ms, 'tied', t.tied
               ) order by t.rank, t.joined_at), '[]'::jsonb)
        from (select s.* from private.session_scores(v_s.id) s
              where not s.removed
              order by s.rank, s.joined_at
              limit 10) t));
  end if;

  return v_result;
end;
$fn$;

revoke all on function public.presenter_get_state(uuid) from public, anon;
grant execute on function public.presenter_get_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- host_get_state: zusätzlich die Medien der aktuellen Frage oder Slide
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
      'question_number', (select count(*) from public.questions q
                          where q.quiz_id = v_q.quiz_id and q.kind = 'question'
                            and (q.position, q.id) <= (v_q.position, v_q.id)));

    if v_q.kind = 'slide' then
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
-- host_save_quiz: zusätzlich Medien prüfen und speichern
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

    v_media := private.clean_media(v_q->'media', v_kind);
    if v_media is null then
      return jsonb_build_object('ok', false, 'error', 'INVALID_MEDIA', 'question', v_qpos);
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

    v_qid := nullif(v_q->>'id', '')::uuid;
    if v_qid is not null then
      update public.questions q
      set position = v_qpos, kind = v_kind, text = v_text, heading = v_heading,
          image_paths = v_images, media = v_media,
          max_selections = case when v_kind = 'slide' then 1 else (v_q->>'max_selections')::int end
      where q.id = v_qid and q.quiz_id = v_quiz_id;
      if not found then v_qid := null; end if;
    end if;
    if v_qid is null then
      insert into public.questions (quiz_id, position, kind, text, heading, image_paths, media, max_selections)
      values (v_quiz_id, v_qpos, v_kind, v_text, v_heading, v_images, v_media,
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

-- ---------------------------------------------------------------------------
-- host_delete_quiz: meldet alle danach unbenutzten Dateien
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

  v_before := private.quiz_files(p_quiz_id);

  delete from public.quizzes z where z.id = p_quiz_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'QUIZ_NOT_FOUND');
  end if;

  return jsonb_build_object('ok', true, 'removed_images', to_jsonb(private.unused_images(v_before)));
end;
$fn$;
