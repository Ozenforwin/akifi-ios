-- Review 2026-11-27: account deletion was broken for EVERY user.
--
-- auth.admin.deleteUser failed with "Database error deleting user"
-- (auth log: relation "assets" does not exist). Deleting the auth user
-- cascades a DELETE on investment_holdings, whose FOR EACH STATEMENT trigger
-- recompute_asset_value_on_holding_change() fires even for 0 rows and refers
-- to `assets` unqualified. GoTrue runs with search_path = auth, so the name
-- did not resolve and the whole deletion rolled back (the old delete-account
-- had already removed most of the user's rows table by table by then).
--
-- Pin search_path on every public function that lacked it (the 18
-- "function_search_path_mutable" advisor warnings), so no caller's
-- search_path can change what they resolve to.

alter function public.budget_norm_name(text) set search_path = public;
alter function public.budget_normalize_period_amount(bigint,text,text) set search_path = public;
alter function public.budget_period_bounds(text,date,date,date,date) set search_path = public;
alter function public.budget_previous_period(text,date,date) set search_path = public;
alter function public.create_expense_with_auto_transfer(uuid,uuid,numeric,text,timestamp with time zone,text,text,uuid,numeric,text) set search_path = public;
alter function public.create_expense_with_auto_transfer(uuid,uuid,numeric,text,timestamp with time zone,text,text,uuid) set search_path = public;
alter function public.fn_savings_goal_updated() set search_path = public;
alter function public.handle_ai_conversations_updated_at() set search_path = public;
alter function public.normalize_budget_before_save() set search_path = public;
alter function public.recompute_asset_value_on_holding_change() set search_path = public;
alter function public.set_assets_updated_at() set search_path = public;
alter function public.set_deposits_updated_at() set search_path = public;
alter function public.set_investment_holdings_updated_at() set search_path = public;
alter function public.set_liabilities_updated_at() set search_path = public;
alter function public.set_savings_challenges_updated_at() set search_path = public;
alter function public.set_user_account_defaults_updated_at() set search_path = public;
alter function public.subscriptions_sync_is_active() set search_path = public;
alter function public.update_category_rules_updated_at() set search_path = public;

-- The statement-level AFTER trigger on investment_holdings fires at the end
-- of GoTrue's DELETE, i.e. as supabase_auth_admin, which may not UPDATE
-- assets ("permission denied for table assets" once the name resolved).
-- It only recomputes current_value of the assets whose holdings changed,
-- from the trigger's own transition tables, so running it as the owner is
-- safe.
alter function public.recompute_asset_value_on_holding_change() security definer;
revoke execute on function public.recompute_asset_value_on_holding_change() from public, anon, authenticated;
