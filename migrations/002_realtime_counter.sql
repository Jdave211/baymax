-- Migration: Update tier checks and add realtime stats for lifetime counter

-- 1. Update the allowed tiers constraint
alter table public.profiles drop constraint if exists profiles_tier_check;
alter table public.profiles add constraint profiles_tier_check 
  check (tier in ('free', 'starter', 'pro', 'max', 'lifetime'));

-- 2. Create a public stats table for realtime counts (bypassing RLS for this specific aggregate)
create table if not exists public.public_stats (
  id text primary key,
  value integer default 0
);

-- Enable RLS and create a public read policy
alter table public.public_stats enable row level security;

drop policy if exists "Public can read stats" on public.public_stats;
create policy "Public can read stats" 
  on public.public_stats for select 
  using (true);

-- Initialize the lifetime_users row
insert into public.public_stats (id, value) 
values ('lifetime_users', 0) 
on conflict do nothing;

-- 3. Create a trigger to keep the stat updated
create or replace function update_lifetime_count()
returns trigger
security definer
language plpgsql
as $$
begin
  if (TG_OP = 'INSERT' and NEW.tier = 'lifetime') or 
     (TG_OP = 'UPDATE' and NEW.tier = 'lifetime' and OLD.tier != 'lifetime') then
    update public.public_stats set value = value + 1 where id = 'lifetime_users';
  elsif (TG_OP = 'UPDATE' and OLD.tier = 'lifetime' and NEW.tier != 'lifetime') or
        (TG_OP = 'DELETE' and OLD.tier = 'lifetime') then
    update public.public_stats set value = value - 1 where id = 'lifetime_users';
  end if;
  return null;
end;
$$;

drop trigger if exists trg_update_lifetime_count on public.profiles;
create trigger trg_update_lifetime_count
after insert or update of tier or delete on public.profiles
for each row execute function update_lifetime_count();

-- 4. Re-calculate the current actual count to be safe
update public.public_stats 
set value = (select count(*)::integer from public.profiles where tier = 'lifetime')
where id = 'lifetime_users';

-- 5. Enable Realtime on the public_stats table so clients can listen via WebSockets
do $$
begin
  alter publication supabase_realtime drop table public.public_stats;
exception when others then
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.public_stats;
exception when others then
end;
$$;
