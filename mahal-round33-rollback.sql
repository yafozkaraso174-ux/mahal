-- REVIEW CANDIDATE. Roll the UI back first and wait for in-flight requests to finish.
-- Non-destructive rollback: keep agreements/allocations and operation history for audit.
-- Existing admin_dashboard/admin_subscription_action are never replaced by round33.
begin;
revoke all on function public.admin_agreement_dashboard(),public.admin_agreement_action(jsonb) from public,anon,authenticated;
revoke all on public.subscription_agreements,public.subscription_allocations from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
-- No DROP/DELETE: preserve recorded balances, receipts and evidence.
-- Re-enable only after a reviewed fix. Never re-run the installation over existing tables.
