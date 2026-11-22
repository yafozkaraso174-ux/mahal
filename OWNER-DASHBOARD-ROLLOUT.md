# Owner dashboard, local candidate

Local branch: owner-dashboard-local. No push, live SQL, tokens or deployment performed.

## Scope

- admin.html only: shops, search/status filters, subscription detail, renewal with optional receipt, standalone receipt, payment history and immutable correction.
- New migration round21: admin-only ledger, idempotency request journal, row/advisory locks, atomic renewal/receipt, audited status reasons, subscription price, attaching a confirmed existing account.
- A suspended shop remains suspended on renewal. Expired subscription must renew before reactivation. Existing open-ended subscriptions need explicit confirmation to become dated subscriptions.
- No password generation, display, clipboard copy or automatic owner messages. Attaching existing confirmed account is implemented locally; new account creation from this screen is intentionally not implemented pending a safe setup decision. This differs from the old password-based create-shop feature.
- Oils/index/store/sw/mobile module untouched. Existing invoice UI untouched. Mobile receivables delivered as separate design images, not implementation.

## Local verification

Run from repository root:

```
python3 build-owner.py
node test/owner-sql.cjs
node test/owner-browser.cjs
node test/harness.js
node test/commerce-core.js
```

Database tests use local embedded PostgreSQL with real migration/RLS/functions, not a live account. They cover permissions, atomic rollback, identical request replay, conflict rejection, date handling, preserving suspension, correction immutability, existing-account attachment and rollback.
Browser tests load actual admin.html with mocked network fixtures and sample shops/receipts; they test same-ID retry after dropped response, month/leap dates, no password fields, and no horizontal overflow at 320/390/1280 widths. Screenshots are actual local app UI with fixture data, not live shops.

True parallel database sessions have not been exercised: local installation has no PostgreSQL server binary. Advisory/row locks are present; production-like two-session race tests remain a release gate. Large-ledger pagination/load tests remain future work.

## Release gates

1. User explicitly approves upload. Zero paid hosting remains mandatory.
2. Decide add-shop setup route. Do not present existing-account attachment as new-account provisioning.
3. Review migration against current live schemas and existing grants, with temporary scoped credentials only after approval.
4. Back up schema/data. Run two-session race tests and migration/RLS/rollback checks in an isolated environment. Keep receipt creation out of the production smoke test unless an explicit test tenant and values are approved.
5. Apply additive round21 before serving new admin.html. It does not rewrite existing tenant dates/status/prices or oils records. Prices remain unset until owner enters them.
6. Deploy on existing free origins only, no URL changes. Keep admin-only migration compatible with rollback to prior admin.html. Legacy admin renewal route exists and reactivates suspended shops, so remove its authenticated execute grant as part of final reviewed cutover, or replace its behavior safely before rollout. Do not leave both workflows active unintentionally.
7. Smoke read-only platform-owner access, normal shop denial, month/filter UI; authorized TEST-only mutation if approved. Compare oils counts before/after and check original invoice screen unchanged.
8. Verify both origins and revoke/delete temporary tokens, verify failure after revocation.

## Rollback

Restore previous admin.html only. Preserve ledger and operation journal, never delete money history to roll back UI. If any owner operation has happened, reconcile its journal before allowing the old renewal workflow, because the legacy workflow has different suspension semantics and no receipt ledger.

# Mobile receivables local candidate

Local approval received after the four mockup screens were reviewed. `mobile-debts.src.js` is bundled by build-commerce.py. Mobile dashboard gets an entry and mobile navigation gets Customers; oils uses its original customer views. Debt total uses the existing customer balance formula exactly once, installment schedule is a breakdown, not another added debt. Existing unlinked incoming receipts with contracts show a reconciliation warning instead of a guessed split.

Round22 adds `payments.contract_id`, an inaccessible mobile receipt request journal, and an admin-independent tenant-scoped RPC that atomically inserts the receipt and advances a selected contract schedule. General receipts do not advance schedules. It validates mobile tenant, tenant active, permissions, customer/contract/invoice relationship, amount and current balance, and expected schedule. Same request ID/body returns prior result; changed payload conflicts. It locks request, customer and contract. Linked receipts are immutable; direct linked inserts and stale schedule overwrites after atomic receipts are blocked.

New mobile receipt UI requires online access and an empty existing outbox. It does not silently enqueue partially linked payments offline. An uncertain send persists the same request locally, with a retry action. A confirmed validation rejection clears it. Old installment collect button routes to the same atomic path. Invoice data/layout are untouched.

Tests: `node test/mobile-debts-sql.cjs` (24 checks), `node test/mobile-debts-browser.cjs` (16 checks). SQL includes tenant/permission rejection, replay/conflicting replay, stale expected schedule, overpayment, precision, rollback of schedule when receipt fails, linked receipt immutability and stale schedule protection. Browser covers network retry, double tap, linked ledger/schedule update, general-receipt ambiguity, legacy oils routing and 320/390/1280 overflow. Actual local app screenshots use sample fixtures, not live shops.

## Combined cutover additions

- Invite flow is mockups only, pending design approval. User chose self-signup via invite rather than existing-account-only creation. Do not ship the current add-existing-account screen as the final new-shop workflow. Keep that screen out of a release until invite design/build is approved and tested.
- Apply round21 then round22 before serving new admin/index. Verify exact current grants/policies first and test separate concurrent database sessions in staging. The local embedded database does not prove parallel-session behavior.
- Before cutover, ensure mobile devices have synced old outboxes; old contract snapshot updates after new linked receipts are deliberately rejected to prevent erasing allocation. Do not discard a blocked legacy queue. Reconcile and refresh with the owner.
- New receipt is online-only, explicitly stated in UI. Existing old offline operations retain their old behavior; no remote wipe or automatic discard.
- Bump app version/cache in the separately approved rollout, inspect both free origins and test old-to-new update path. sw.js has not been modified in this local candidate.
- Monitor actual production errors after approved deployment, particularly stale contract snapshot rejections and blocked old client queues. No standing monitoring has been started.
- Rollback does not remove receipt links, journals or guards. Do not re-enable old installment collectors on contracts with linked receipts without reconciliation.

# Final local gate update, invite and compatibility

Supersedes the earlier pending-invite and maintenance-window sections above:

- User approved invite flow and combined upload at 22:37, original WhatsApp message ending QTVBNUI0NUUzQTA2NTRGRjEyRjZEMEE4NUVFOUFCNDMA. Main instructed no live access/tokens until local gates pass and screenshots are reported.
- Invitation flow implemented in round23, admin-invites.src.js and join.html. 48 hours, single successful use, tenant/email-bound, revocation/reissue, starts subscription at acceptance. Recipient sets password privately on the signup form. If provider requires email confirmation, signup explains it and recipient returns to original invitation and signs in. No platform-owner message is auto-sent. Backend stores SHA256 token hash only, no bearer in the request journal. Client sends fragment token only to owning backend and clears URL fragment immediately. Token is retained in memory only on join page. Owner can copy current link; later retrieval means reissue, not recovering token.
- admin_attach_shop and superseded direct provisioning/status/renewal RPC grants are removed from authenticated in round23. Existing normal app functionality remains untouched. Invited tenants are suspended until accepted, with separate onboarding status.
- Local SQL tests: invitations 20, legacy queue compatibility 14. Invite UI 14. Race tests now run on an actual isolated PostgreSQL server with two independent sessions: same-id renewal (one receipt/renewal); distinct stale renewals (one rejected); same invite create/accept replay (one shop/membership); same legacy receipt replay and distinct legacy concurrent receipts (no duplicates or lost schedule updates).
- Round24 compatibility upgrades old named installment-payment requests to the new atomic path, then acknowledges matching old schedule snapshots without reducing current paid totals. Pre-upgrade receipts with a delayed schedule update may advance the schedule only as far as matching existing receipts fund it. It does not drop queues, wipe data or require user maintenance. Ambiguous/malformed legacy requests remain rejected without recording a new receipt. Existing already-saved legacy payment retry preserves its original response. Unrelated oils record_payment delegates to the original function unchanged.
- Apply round21,22,23,24 in that order, in reviewed transactions, after live schema/grant baseline and backup. Preview exact live record_payment and contract shape before applying compatibility. Keep both original function and migration artifacts for rollback, and do not delete journals/receipts.
- App version r40 and cache v41 bump only, no change in offline cache routing logic. join.html remains online-only and is not cached as index. Existing free origins stay unchanged.
- Still needed after live access approval: source-of-truth schema/auth-settings read, compare policies and function signatures, inspect email confirmation behavior without sending unauthorized test mail; deploy exact approved files only; read-only live app checks and authorized TEST-only receipt/invite test if a real isolated recipient/account is available and approved. Do not invite any real person or create any real subscription payment as a test without authority.
