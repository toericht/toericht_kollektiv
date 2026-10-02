-- töricht live – Phase 2: Tabellen, RLS, Rechte
-- Im Supabase SQL Editor einmalig ausführen (vor 002_functions.sql).

create schema if not exists private;

create type public.game_state as enum (
  'LOBBY',
  'QUESTION_OPEN',
  'QUESTION_CLOSED',
  'RESULTS',
  'LEADERBOARD',
  'FINAL_RESULTS',
  'ENDED'
);

-- ---------------------------------------------------------------------------
-- Tabellen
-- ---------------------------------------------------------------------------

-- Allowlist der Host-Accounts
create table public.hosts (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.quizzes (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (char_length(title) between 1 and 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.questions (
  id             uuid primary key default gen_random_uuid(),
  quiz_id        uuid not null references public.quizzes (id) on delete cascade,
  position       int  not null default 0,
  text           text not null check (char_length(text) between 1 and 500),
  -- 1 = Single Choice, >1 = Multiple Choice
  max_selections int  not null default 1 check (max_selections >= 1),
  created_at     timestamptz not null default now()
);
create index questions_quiz_position_idx on public.questions (quiz_id, position, id);

create table public.answer_options (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions (id) on delete cascade,
  position    int  not null default 0,
  label       text not null check (char_length(label) between 1 and 200),
  -- darf negativ sein; verlässt die DB nur über Host-Funktionen
  points      int  not null default 0
);
create index answer_options_question_position_idx on public.answer_options (question_id, position, id);

create table public.game_sessions (
  id                  uuid primary key default gen_random_uuid(),
  quiz_id             uuid not null references public.quizzes (id),
  join_code           text not null unique,
  state               public.game_state not null default 'LOBBY',
  current_question_id uuid references public.questions (id),
  -- wird bei jedem Zustandswechsel erhöht (Optimistic Locking + Realtime-Signal)
  version             int  not null default 1,
  join_locked         boolean not null default false,
  recovery_failures   int  not null default 0,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  state_changed_at    timestamptz not null default now(),
  ended_at            timestamptz
);

create table public.players (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.game_sessions (id) on delete cascade,
  -- bewusst NICHT unique; Identität ist ausschließlich die id
  nickname     text not null check (char_length(nickname) between 1 and 24),
  -- SHA-256 des geheimen Spieler-Tokens; das Token selbst wird nie gespeichert
  token_hash   text not null unique,
  removed      boolean not null default false,
  joined_at    timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index players_session_idx on public.players (session_id);

create table public.player_answers (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid not null references public.game_sessions (id) on delete cascade,
  player_id      uuid not null references public.players (id) on delete cascade,
  question_id    uuid not null references public.questions (id),
  option_ids     uuid[] not null,
  points_awarded int    not null,
  -- fortlaufende Nummer des Clients; nur höhere Nummern überschreiben
  client_seq     bigint not null default 0,
  submitted_at   timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- genau eine gültige Antwort pro Person und Frage
  unique (player_id, question_id)
);
create index player_answers_session_question_idx on public.player_answers (session_id, question_id);

create table public.recovery_codes (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.game_sessions (id) on delete cascade,
  player_id  uuid not null references public.players (id) on delete cascade,
  code_hash  text not null,
  expires_at timestamptz not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);
create index recovery_codes_lookup_idx on public.recovery_codes (session_id, code_hash);

-- ---------------------------------------------------------------------------
-- Host-Prüfung
-- ---------------------------------------------------------------------------

create or replace function public.is_host()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.hosts h where h.user_id = (select auth.uid()));
$$;

revoke all on function public.is_host() from public;
grant execute on function public.is_host() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rechte: anon bekommt keinerlei Tabellenzugriff.
-- Hosts bearbeiten Quiz-Inhalte direkt (Editor), alles andere läuft über Funktionen.
-- ---------------------------------------------------------------------------

revoke all on table
  public.hosts, public.quizzes, public.questions, public.answer_options,
  public.game_sessions, public.players, public.player_answers, public.recovery_codes
from anon, authenticated;

grant select on table public.hosts to authenticated;
grant select, insert, update, delete on table public.quizzes, public.questions, public.answer_options to authenticated;
grant select on table public.game_sessions to authenticated;

alter table public.hosts          enable row level security;
alter table public.quizzes        enable row level security;
alter table public.questions      enable row level security;
alter table public.answer_options enable row level security;
alter table public.game_sessions  enable row level security;
alter table public.players        enable row level security;
alter table public.player_answers enable row level security;
alter table public.recovery_codes enable row level security;

create policy hosts_select_self on public.hosts
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy quizzes_host_all on public.quizzes
  for all to authenticated
  using ((select public.is_host()))
  with check ((select public.is_host()));

create policy questions_host_all on public.questions
  for all to authenticated
  using ((select public.is_host()))
  with check ((select public.is_host()));

create policy answer_options_host_all on public.answer_options
  for all to authenticated
  using ((select public.is_host()))
  with check ((select public.is_host()));

create policy game_sessions_host_select on public.game_sessions
  for select to authenticated
  using ((select public.is_host()));

-- players, player_answers, recovery_codes: absichtlich keine Policies.
