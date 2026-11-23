# Subscription balance candidate, local review only

## What changes
- Owner subscriptions and shop detail show fixed agreement total, allocated valid receipts, remaining balance and any excess credit.
- Example test data: 6 × 300 = 1800 EGP; paid 600; balance 1200. Coverage is a money equivalent, not calendar-month settlement.
- New receipt goes to the current agreement. Renewal creates a new fixed-rate agreement and allocates its accompanying receipt there. Old balances and credits stay visible in agreement history. No automatic credit transfer or extension.
- Existing shops show “agreement needs review” until the owner explicitly enters months/rate and selects historical receipts. No automatic debt backfill. Existing receipt IDs are linked, not duplicated.
- If an old client changes subscription end outside the new agreement flow, display and new balance writes stop for review rather than pretend the new dates match the financial agreement.

## SQL step, separate approval required
Run mahal-round33-agreement-balances.sql only after explicit approval and a fresh prerequisite check. It runs in one transaction and adds:
1. subscription_agreements, fixed months/rate/total and optional reviewed dates.
2. subscription_allocations, one receipt linked to one agreement in the same shop.
3. Owner-only admin_agreement_dashboard / admin_agreement_action functions.

Installation does not change tenant dates, status or price; does not rewrite old receipts; does not backfill any shop; does not charge or collect money. Existing owner functions are not replaced. New tables are RLS-enabled and inaccessible directly to ordinary authenticated or anonymous clients. Owner-only checked functions read/write them. Every operation uses an idempotency ID and locks its shop during changes.

## Rollout order
- Recheck live function/schema compatibility without mutation. Captured production function definitions informed local tests, but are not a current full schema export.
- Get direct yes to this exact SQL step and publication approval for the exact UI candidate.
- Save current static files and apply SQL first. Verify owner-only access and no data backfill.
- Publish only admin.html and source/build/SQL files agreed for repository sync. Do not change index/store/join/sw or invoice.
- With the owner, verify actual authenticated account display. There is no platform-owner login available in this work.
- Reconcile each existing shop explicitly before claiming a real balance. The pictured example is not proof that a production shop owes 1200.

## Rollback
Restore the pre-candidate owner UI, then run mahal-round33-rollback.sql with separate approval if needed. It revokes new function access and keeps financial tables and audit data. No destructive DROP or DELETE is included. Existing owner dashboard/action functions remain unchanged and usable. Reinstalling blindly is refused if round33 tables exist.

## Compatibility boundaries
- Receipts/corrections retain the existing ledger and existing server validation. Correcting an allocated receipt removes it from calculated paid value without deleting the original.
- Legacy unallocated payments remain in the payment log and do not silently count toward any agreement.
- Legacy in-flight sent requests retry through their original endpoint and exact body, not a transformed new action.
- Missing new RPC falls back to the old dashboard; no invented balance. Other loading errors do not fall back to stale values.
- No invoice, store, join, service-worker or customer-app changes. No new dependency or paid service.
- This is not a debt-aging or installment-due feature. It does not claim that the full remaining amount is due today.
- New UI does not support automatic historical debt reconstruction or moving credit between agreements. Those are separate future workflows.

## Tests and evidence
- 47 disposable local PostgreSQL-compatible checks: example totals, existing functions unchanged, selected historical receipts, invalid/cross-shop/corrected entries, exact retries, conflicts, new receipts, price immutability, renewal, credit, correction, authorization and non-destructive rollback.
- 30 browser assertions on the candidate using synthetic data and intercepted account calls: 320/390/1280 widths, arithmetic display, filters, request routing, review data, excess/zero-rate display, missing agreement guard, mismatch guard, legacy pending-request preservation and no JS page errors.
- Earlier 23 owner-browser and 17 invitation-browser assertions were rerun against their existing configured baseline paths, not this candidate. They are baseline evidence only, not 40 extra candidate checks.
- Actual pixels inspected at 320 and 390. Full detail plus focused detail and subscriptions screenshots provided. The long detail screenshot includes all preserved account controls.

All work local. No SQL on Supabase, no push, no deploy, no charge.
