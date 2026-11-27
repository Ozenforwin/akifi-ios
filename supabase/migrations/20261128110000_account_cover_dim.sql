-- Account cover dimming (1.6.0): how dark the legibility scrim over an
-- account's cover photo is.
--
-- Vladimir, 2026-11-28: «может добавить в настройки уровень затемнения,
-- типо ползунка»; decided «Общий, как фото» — the OWNER sets it and every
-- member of a shared account sees the same card, like the cover itself
-- (20261128100000_account_covers.sql).
--
-- accounts.cover_dim:
--   null    automatic — the app computes the least darkening that keeps the
--           card's text at WCAG AA, from the photo itself;
--   0…100   the owner's choice from «Светлее» (0) to «Темнее» (100). The
--           app maps it onto the scrim and never goes lighter than its own
--           readability floor.
-- Only the owner may change it (trigger, 42501 account_cover_owner_only —
-- the same error the cover guard raises); editors may still rename the
-- account. The service role and the database owner are not restricted.

alter table public.accounts add column if not exists cover_dim smallint;

comment on column public.accounts.cover_dim is
    'Account cover dimming: null = automatic, 0..100 = lighter..darker. Set only by the account owner (migration 20261128110000).';

alter table public.accounts drop constraint if exists accounts_cover_dim_check;
alter table public.accounts
    add constraint accounts_cover_dim_check
    check (cover_dim is null or cover_dim between 0 and 100);

create or replace function public.guard_account_cover_dim()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_owner uuid;
begin
    if coalesce(auth.role(), '') not in ('authenticated', 'anon') then
        return new;
    end if;

    if tg_op = 'INSERT' then
        if new.cover_dim is null then
            return new;
        end if;
        v_owner := new.user_id;
    else
        if new.cover_dim is not distinct from old.cover_dim then
            return new;
        end if;
        v_owner := old.user_id;
    end if;

    if v_owner is distinct from auth.uid() then
        raise exception 'account_cover_owner_only: only the owner of the account can change its cover'
            using errcode = '42501';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_account_cover_dim() from public, anon, authenticated;

drop trigger if exists guard_account_cover_dim on public.accounts;
create trigger guard_account_cover_dim
    before insert or update of cover_dim on public.accounts
    for each row execute function public.guard_account_cover_dim();

comment on function public.guard_account_cover_dim() is
    'Account covers: clients change accounts.cover_dim only as the account owner (migration 20261128110000).';
