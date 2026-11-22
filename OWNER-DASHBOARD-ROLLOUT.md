# Combined rollout, local release candidate

## Approved scope
Owner shops/subscriptions dashboard, mobile receivables, email-bound self-signup invitation. The original invoice screen, oils data and existing free origins stay unchanged. No photo-upload-order bug work. No automatic invitations/messages. Pending shops cannot use the service. The recipient chooses their password. Subscription begins at acceptance. Invitation lasts one hour, is single-use, revocable and bound to shop/email.

## Local evidence
- Owner SQL 35 and UI 23 checks.
- Mobile SQL 24 and UI 16 checks.
- Invitation SQL 23 and UI 17 checks, including unconfirmed email, wrong email, non-admin, expired/revoked token, reissue, replay, signup confirmation branch, double click and narrow/wide layouts.
- Legacy receipt compatibility 18 checks. Preserves old receipt date and ID. Includes pre-upgrade saved receipt with pending schedule, followed by newer receipt before the old snapshot reaches the server.
- Independent actual PostgreSQL sessions: same-ID renewal applies once, conflicting renewals reject stale end date, invite creation/acceptance replay yields one shop/membership, legacy same-ID receipt applies once and distinct receipts do not lose schedule updates.
- Original 223, commerce core 38, commerce SQL 32, commerce UI 28, storefront UI 10 and service-worker isolation 4 regression checks passed. No page errors in the exercised UI tests.
- App r40, offline cache v41. Cache behavior is unchanged. Online-only join page cannot replace offline index shell.
- Actual local invite screenshots supplied to main, using fixtures and intercepted network, not a deployed invitation.

## Compatibility behavior and limits
Old installment collection enqueues a payment then a contract snapshot. Round24 maps uniquely identified legacy requests to atomic receipt handling. Matching stale snapshots are acknowledged without reducing authoritative allocations. Before adding a receipt, matching real saved receipts form a paid floor, covering a pre-upgrade receipt whose schedule is delayed. Linked receipts and contract identities cannot be silently rewritten. General/oils payments delegate to the original record_payment implementation.

Invalid/ambiguous contract identifiers, inconsistent data or genuine overcollection still fail safely instead of dropping a queue or guessing a contract. Local tests do not establish the contents of unseen devices' queues. Live preflight must check mobile contract uniqueness, totals and legacy receipt/schedule consistency. A mismatch blocks rollout and is reported, not silently repaired. No data wipe, forced queue clearing, user maintenance window or skipped operations.

## Ordered live gates, not yet run
1. Confirm current production HEAD/baseline. Read-only schema, RPC definitions, RLS/grants and counts. Capture current record_payment, compare the legacy fixture, and inspect contract/customer/invoice relations and legacy receipt shapes. Check Auth email/password signup, email confirmation, site URL and redirect settings without changing settings or sending test mail.
2. If preflight matches, preserve full definitions/grants plus affected data backup. Apply round21,22,23,24 in order, each in its reviewed transaction. Verify grants and data counts. Any mismatch stops deployment.
3. Deploy exact approved frontend files including join.html to existing GitHub Pages and Workers origins, with r40/v41. No domain/URL change or paid hosting.
4. Check both origins, dashboard, mobile receivables and invite-invalid flow. Real invitation/signup test only with an explicitly authorized isolated email/account, since it can send mail/create a shop. Do not send a real invitation or record a real payment merely as a test.
5. Recheck oils baseline and tenant isolation. Record final migration/application state. Revoke all temporary provider credentials and remove local copies; verify revocation at the provider. If a live gate fails, stop and report exact state and safe recovery route.

## Recovery
Keep original function definitions and deployment artifacts. Do not delete operation journals, receipts or successful memberships to undo a UI release. Roll back frontend if needed; linked receipt protections remain until reviewed data-preserving recovery. No arbitrary destructive down migration.

## Access required, after main approval
- Supabase project: SQL read/preflight, reviewed migration execution and read verification; Auth configuration read only. No auth-config changes or real recipient test without additional approval. Dashboard session can avoid a management token. If temporary credentials are necessary, collect them privately, never in chat.
- GitHub repository: push approved code to the existing publish branch and read Pages/deploy result. No new repository, visibility/audience change or unrelated files.
- Cloudflare existing mahal Worker: deploy static assets and read deployment result only. No domain/DNS, billing or paid services. If using a temporary token, restrict it to the existing account's Workers deployment permissions and revoke it immediately after the verified rollout.

No live access, token creation, push or SQL migration has been performed for this candidate yet.
