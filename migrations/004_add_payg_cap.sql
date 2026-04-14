-- Add pay-as-you-go fields to profiles table
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS stripe_payg_subscription_id TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS stripe_payg_item_id TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS payg_usage_this_period INTEGER DEFAULT 0;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS payg_cap_cents INTEGER DEFAULT 1000;
