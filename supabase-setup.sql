-- ============================================================
--  Bryton Café — Call Waiter
--  Run once in Supabase → SQL Editor → New query → Run
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- MEJA / TABLES ----------
create table if not exists public.tables (
  id         text primary key,          -- short code used in the QR url, e.g. l1-05
  label      text not null,             -- what staff and customers see, e.g. "Meja 1.5"
  floor      smallint not null default 1,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- SETTINGS (single row) ----------
create table if not exists public.settings (
  id               smallint primary key default 1,
  open_time        time    not null default '08:00',
  close_time       time    not null default '22:00',
  cooldown_seconds int     not null default 60,
  accepting_calls  boolean not null default true,
  cafe_name        text    not null default 'Bryton Café',
  constraint settings_singleton check (id = 1)
);
insert into public.settings (id) values (1) on conflict (id) do nothing;

-- ---------- CALLS ----------
create table if not exists public.calls (
  id         uuid primary key default gen_random_uuid(),
  table_id   text not null references public.tables(id) on delete cascade,
  kind       text not null check (kind in ('waiter','bill','clean','other')),
  message    text,
  status     text not null default 'open' check (status in ('open','ack','done')),
  created_at timestamptz not null default now(),
  acked_at   timestamptz,
  done_at    timestamptz
);

create index if not exists calls_status_idx on public.calls (status, created_at desc);
create index if not exists calls_table_recent_idx on public.calls (table_id, created_at desc);

-- ============================================================
--  ROW LEVEL SECURITY
--  anon  = any customer with the public key (it IS public, that's fine)
--  authenticated = your staff login
-- ============================================================

alter table public.tables   enable row level security;
alter table public.settings enable row level security;
alter table public.calls    enable row level security;

drop policy if exists "anon reads active tables" on public.tables;
create policy "anon reads active tables" on public.tables
  for select to anon using (active = true);

drop policy if exists "anon reads settings" on public.settings;
create policy "anon reads settings" on public.settings
  for select to anon using (true);

drop policy if exists "staff manage tables" on public.tables;
create policy "staff manage tables" on public.tables
  for all to authenticated using (true) with check (true);

drop policy if exists "staff manage settings" on public.settings;
create policy "staff manage settings" on public.settings
  for all to authenticated using (true) with check (true);

drop policy if exists "staff manage calls" on public.calls;
create policy "staff manage calls" on public.calls
  for all to authenticated using (true) with check (true);

-- Deliberately NO anon policy on public.calls.
-- Customers can neither read other tables' messages nor insert directly.
-- Their only route in is create_call() below.

-- ============================================================
--  create_call() — the one door customers may use
--  Validates table, opening hours, pause switch and cooldown.
-- ============================================================

create or replace function public.create_call(
  p_table   text,
  p_kind    text,
  p_message text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  s         public.settings%rowtype;
  t         public.tables%rowtype;
  now_jkt   time;
  is_open   boolean;
  last_at   timestamptz;
  wait_s    int;
  clean_msg text;
begin
  select * into s from public.settings where id = 1;
  select * into t from public.tables where id = p_table and active;

  if t.id is null then
    return json_build_object('ok', false, 'error', 'unknown_table');
  end if;

  if p_kind not in ('waiter','bill','clean','other') then
    return json_build_object('ok', false, 'error', 'bad_kind');
  end if;

  if not s.accepting_calls then
    return json_build_object('ok', false, 'error', 'paused');
  end if;

  now_jkt := (now() at time zone 'Asia/Jakarta')::time;
  if s.open_time <= s.close_time then
    is_open := now_jkt >= s.open_time and now_jkt < s.close_time;
  else
    -- opening hours cross midnight, e.g. 10:00 → 01:00
    is_open := now_jkt >= s.open_time or now_jkt < s.close_time;
  end if;

  if not is_open then
    return json_build_object(
      'ok', false, 'error', 'closed',
      'open_time',  to_char(s.open_time,  'HH24:MI'),
      'close_time', to_char(s.close_time, 'HH24:MI'));
  end if;

  select max(created_at) into last_at
    from public.calls
   where table_id = t.id
     and created_at > now() - make_interval(secs => s.cooldown_seconds);

  if last_at is not null then
    wait_s := ceil(extract(epoch from
      (last_at + make_interval(secs => s.cooldown_seconds)) - now()));
    return json_build_object('ok', false, 'error', 'cooldown',
                             'wait_seconds', greatest(wait_s, 1));
  end if;

  clean_msg := nullif(btrim(left(coalesce(p_message, ''), 200)), '');

  insert into public.calls (table_id, kind, message)
  values (t.id, p_kind, clean_msg);

  return json_build_object('ok', true,
                           'table_label', t.label,
                           'cooldown', s.cooldown_seconds);
end;
$$;

revoke all on function public.create_call(text, text, text) from public;
grant execute on function public.create_call(text, text, text) to anon, authenticated;

-- ============================================================
--  REALTIME — so the dashboard hears new calls instantly
-- ============================================================
do $$
begin
  alter publication supabase_realtime add table public.calls;
exception
  when duplicate_object then null;
end $$;

-- ============================================================
--  SAMPLE TABLES — delete or edit these, or use the dashboard's
--  "Kelola Meja" panel to bulk-add per floor.
-- ============================================================
insert into public.tables (id, label, floor) values
  ('l1-01', 'Meja 1.1', 1),
  ('l1-02', 'Meja 1.2', 1),
  ('l2-01', 'Meja 2.1', 2),
  ('l3-01', 'Meja 3.1', 3)
on conflict (id) do nothing;
