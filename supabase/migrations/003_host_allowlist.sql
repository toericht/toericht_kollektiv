-- töricht live – Phase 2: Host-Account in die Allowlist eintragen
-- Voraussetzung: Der Account existiert unter Authentication → Users.

insert into public.hosts (user_id)
select u.id from auth.users u where lower(u.email) = 'hello@toericht.eu'
on conflict (user_id) do nothing;

-- Kontrolle: muss genau eine Zeile zurückgeben
select u.email from public.hosts h join auth.users u on u.id = h.user_id;
