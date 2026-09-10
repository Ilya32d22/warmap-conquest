-- WARMAP CONQUEST v18 - clans backend
-- Run this whole file once in Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 24),
  total_reps bigint not null default 0 check (total_reps >= 0),
  countries_captured integer not null default 0 check (countries_captured >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.daily_stats (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  reps integer not null default 0 check (reps >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);

create table if not exists public.clans (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 32),
  invite_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.clan_members (
  clan_id uuid not null references public.clans(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (clan_id,user_id),
  unique (user_id)
);

alter table public.profiles enable row level security;
alter table public.daily_stats enable row level security;
alter table public.clans enable row level security;
alter table public.clan_members enable row level security;

-- The browser never gets direct table access; only the RPCs below are exposed.
revoke all on public.profiles, public.daily_stats, public.clans, public.clan_members from anon, authenticated;

create or replace function public.sync_my_stats(
  p_display_name text,
  p_total_reps bigint,
  p_countries_captured integer,
  p_day date,
  p_day_reps integer
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := trim(p_display_name);
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 24 then raise exception 'Имя: 2-24 символа'; end if;

  insert into public.profiles(user_id,display_name,total_reps,countries_captured,updated_at)
  values(v_uid,v_name,greatest(0,p_total_reps),greatest(0,p_countries_captured),now())
  on conflict(user_id) do update set
    display_name=excluded.display_name,
    total_reps=greatest(public.profiles.total_reps,excluded.total_reps),
    countries_captured=excluded.countries_captured,
    updated_at=now();

  insert into public.daily_stats(user_id,day,reps,updated_at)
  values(v_uid,p_day,greatest(0,p_day_reps),now())
  on conflict(user_id,day) do update set
    reps=greatest(public.daily_stats.reps,excluded.reps),
    updated_at=now();
end;
$$;

create or replace function public.create_clan(p_name text)
returns table(clan_id uuid, clan_name text, invite_code text, role text, member_count bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_code text;
  v_name text := trim(p_name);
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 32 then raise exception 'Название: 2-32 символа'; end if;
  if exists(select 1 from public.clan_members where user_id=v_uid) then raise exception 'Вы уже состоите в клане'; end if;

  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''),1,8));
    exit when not exists(select 1 from public.clans where invite_code=v_code);
  end loop;

  insert into public.clans(name,invite_code,owner_id) values(v_name,v_code,v_uid) returning id into v_id;
  insert into public.clan_members(clan_id,user_id,role) values(v_id,v_uid,'owner');
  return query select v_id,v_name,v_code,'owner'::text,1::bigint;
end;
$$;

create or replace function public.join_clan(p_invite_code text)
returns table(clan_id uuid, clan_name text, invite_code text, role text, member_count bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_clan public.clans%rowtype;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if exists(select 1 from public.clan_members where user_id=v_uid) then raise exception 'Вы уже состоите в клане'; end if;
  select * into v_clan from public.clans where invite_code=upper(trim(p_invite_code)) limit 1;
  if v_clan.id is null then raise exception 'Клан с таким кодом не найден'; end if;
  insert into public.clan_members(clan_id,user_id,role) values(v_clan.id,v_uid,'member');
  return query select v_clan.id,v_clan.name,v_clan.invite_code,'member'::text,(select count(*) from public.clan_members cm where cm.clan_id=v_clan.id);
end;
$$;

create or replace function public.get_my_clan()
returns table(clan_id uuid, clan_name text, invite_code text, role text, member_count bigint)
language sql
security definer
set search_path = public
stable
as $$
  select c.id,c.name,c.invite_code,cm.role,
         (select count(*) from public.clan_members x where x.clan_id=c.id)
  from public.clan_members cm
  join public.clans c on c.id=cm.clan_id
  where cm.user_id=auth.uid()
  limit 1;
$$;

create or replace function public.get_clan_leaderboard()
returns table(
  user_id uuid,
  display_name text,
  role text,
  day_reps bigint,
  week_reps bigint,
  month_reps bigint,
  countries_captured integer,
  total_reps bigint
)
language sql
security definer
set search_path = public
stable
as $$
  with mine as (
    select clan_id from public.clan_members where user_id=auth.uid() limit 1
  )
  select p.user_id,p.display_name,cm.role,
         coalesce(sum(ds.reps) filter (where ds.day=current_date),0)::bigint as day_reps,
         coalesce(sum(ds.reps) filter (where ds.day>=date_trunc('week',current_date)::date and ds.day<=current_date),0)::bigint as week_reps,
         coalesce(sum(ds.reps) filter (where ds.day>=date_trunc('month',current_date)::date and ds.day<=current_date),0)::bigint as month_reps,
         p.countries_captured,p.total_reps
  from mine
  join public.clan_members cm on cm.clan_id=mine.clan_id
  join public.profiles p on p.user_id=cm.user_id
  left join public.daily_stats ds on ds.user_id=p.user_id and ds.day>=date_trunc('month',current_date)::date and ds.day<=current_date
  group by p.user_id,p.display_name,cm.role,p.countries_captured,p.total_reps,cm.joined_at
  order by week_reps desc, month_reps desc, p.total_reps desc, cm.joined_at asc;
$$;

revoke all on function public.sync_my_stats(text,bigint,integer,date,integer) from public, anon, authenticated;
revoke all on function public.create_clan(text) from public, anon, authenticated;
revoke all on function public.join_clan(text) from public, anon, authenticated;
revoke all on function public.get_my_clan() from public, anon, authenticated;
revoke all on function public.get_clan_leaderboard() from public, anon, authenticated;

grant execute on function public.sync_my_stats(text,bigint,integer,date,integer) to authenticated;
grant execute on function public.create_clan(text) to authenticated;
grant execute on function public.join_clan(text) to authenticated;
grant execute on function public.get_my_clan() to authenticated;
grant execute on function public.get_clan_leaderboard() to authenticated;
