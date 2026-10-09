-- Run this in Supabase Dashboard > SQL Editor before creating the first Yurei account.
-- Replace the placeholder with the exact email address you will use to sign up.
-- This authorizes only that email to claim the first administrator account.
insert into public.bootstrap_admins(email)
values (lower(trim('REPLACE-WITH-YOUR-ADMIN-EMAIL')))
on conflict (email) do update set claimed_at = null;
