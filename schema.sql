-- Enable pgvector for hybrid search/embeddings
create extension if not exists vector;

-- Profiles table for users
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  email text unique not null,
  full_name text,
  avatar_url text,
  tier text default 'free' check (tier in ('free', 'pro')),
  
  -- Stripe subscription fields
  stripe_customer_id text unique,
  stripe_subscription_id text unique,
  subscription_status text check (subscription_status in ('active', 'canceled', 'incomplete', 'incomplete_expired', 'past_due', 'paused', 'trialing', 'unpaid')),
  current_period_end timestamp with time zone,
  
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Index for Stripe customer lookups
create index if not exists idx_profiles_stripe_customer_id on public.profiles(stripe_customer_id);

-- Enable RLS on profiles
alter table public.profiles enable row level security;

create policy "Users can view their own profile"
  on public.profiles for select
  using ( auth.uid() = id );

create policy "Users can update their own profile"
  on public.profiles for update
  using ( auth.uid() = id );

-- Logs table for Baymax interactions
create table if not exists public.baymax_logs (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users on delete cascade not null,
  
  -- Interaction details
  transcript text not null,
  ai_response text not null,
  character_name text not null,
  character_color text not null,
  
  -- Screenshots (URLs to storage)
  screenshot_before_url text,
  screenshot_after_url text,
  
  -- Hybrid search/embeddings (768-dim from Cloudflare Workers AI bge-base-en-v1.5)
  embedding vector(768),
  
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Enable RLS on logs
alter table public.baymax_logs enable row level security;

create policy "Users can view their own logs"
  on public.baymax_logs for select
  using ( auth.uid() = user_id );

create policy "Users can insert their own logs"
  on public.baymax_logs for insert
  with check ( auth.uid() = user_id );

-- Function to handle new user signup and create a profile
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (new.id, new.email, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'avatar_url');
  return new;
end;
$$ language plpgsql security definer;

-- Trigger to call handle_new_user on signup
create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Storage buckets for screenshots
-- Note: Supabase storage is managed via API, but we can set up policies here
-- This assumes buckets named 'screenshots-before' and 'screenshots-after' exist

-- Create a function to search logs with hybrid search (text + vector)
create or replace function search_baymax_logs(
  query_text text,
  query_embedding vector(768),
  match_threshold float,
  match_count int
)
returns table (
  id uuid,
  transcript text,
  ai_response text,
  created_at timestamp with time zone,
  similarity float
)
language plpgsql
as $$
begin
  return query
  select
    baymax_logs.id,
    baymax_logs.transcript,
    baymax_logs.ai_response,
    baymax_logs.created_at,
    1 - (baymax_logs.embedding <=> query_embedding) as similarity
  from baymax_logs
  where 
    (baymax_logs.transcript ilike '%' || query_text || '%' or baymax_logs.ai_response ilike '%' || query_text || '%')
    and baymax_logs.embedding is not null
    and 1 - (baymax_logs.embedding <=> query_embedding) > match_threshold
  order by similarity desc
  limit match_count;
end;
$$;
