-- töricht live – Farbliche Auflösung der Antworten (grün / gelb / rot)
-- Im Supabase SQL Editor ausführen (nach 004). Kann wiederholt ausgeführt werden.
--
-- Ändert nur, was get_state im Zustand RESULTS zusätzlich liefert: pro Antwort
-- eine Stufe statt des Punktwerts und die eigenen Punkte für diese Frage
-- (my_question_score). Punkte- und Antwortlogik bleiben unverändert.
--   best = höchste positive Punktzahl der Frage (bei Gleichstand mehrere)
--   good = positive Punktzahl unter dem Maximum
--   bad  = 0 oder negative Punktzahl
-- Solange die Frage offen oder nur geschlossen ist, wird keine Stufe geliefert.

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
$$;
