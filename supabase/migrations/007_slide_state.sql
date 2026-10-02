-- töricht live – neuer Spielzustand SLIDE
-- Im Supabase SQL Editor ausführen, ALLEIN und VOR 008_slides_images.sql.
-- Postgres erlaubt es nicht, einen neuen Zustand im selben Lauf anzulegen und
-- zu benutzen; deshalb steht diese eine Zeile in einer eigenen Datei.

alter type public.game_state add value if not exists 'SLIDE';
