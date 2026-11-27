-- Review 2026-11-27, S17: ios-migrate-auth turns a 6-character Telegram
-- migration code into a full session. There was no attempt limit and the
-- "used" flag was set without a condition, so codes could be enumerated and
-- one code redeemed twice by parallel requests. Failed attempts are now
-- recorded here (service role only) and capped per IP and globally; the
-- function claims a code with a conditional update.
create table if not exists public.migration_code_attempts (
    ip text        not null,
    at timestamptz not null default now()
);
create index if not exists migration_code_attempts_at_idx on public.migration_code_attempts (at desc);
create index if not exists migration_code_attempts_ip_at_idx on public.migration_code_attempts (ip, at desc);
alter table public.migration_code_attempts enable row level security;
revoke all on public.migration_code_attempts from anon, authenticated;
