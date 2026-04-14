-- Migration: Add Stripe subscription fields to profiles table
-- Run this if the profiles table already exists

-- Add Stripe columns if they don't exist
alter table public.profiles 
add column if not exists stripe_customer_id text unique;

alter table public.profiles 
add column if not exists stripe_subscription_id text unique;

alter table public.profiles 
add column if not exists subscription_status text 
check (subscription_status in ('active', 'canceled', 'incomplete', 'incomplete_expired', 'past_due', 'paused', 'trialing', 'unpaid'));

alter table public.profiles 
add column if not exists current_period_end timestamp with time zone;

-- Create index for faster Stripe customer lookups
create index if not exists idx_profiles_stripe_customer_id 
on public.profiles(stripe_customer_id);

-- Grant service role permission to update profiles (for webhook)
-- This allows the Cloudflare Worker using the service key to update profiles
grant update on public.profiles to service_role;
