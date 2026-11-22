# Offers, units and per-tenant storefronts

Batch rollout approved November 22, 2026. Round19 and round20 applied after baseline verification. Keep hosting free and preserve existing links.

## Scope

- Owner-only offer editing, tenant-scoped sync, percentage or fixed per-base-unit discounts, optional dates and on/off.
- One active offer per product and date range. Reject overlap on the server. No stacking with invoice discounts.
- Extra sale route for Offers/weight/units. Existing invoice route/layout stays intact. Configured products use the extra route to avoid silently omitting an offer or losing gram precision.
- Future invoice discounts require a reason. The old invoice layout asks through a separate sheet at save time.
- Price, offer name, quantities and conversion are saved as invoice-item JSON. Old invoices are not repriced.
- Mobile checkout retains separate manufacturer/shop warranties and adds product Offers. Quote changes require review.
- Kg with three decimals, sacks, pieces/cartons, square metres and linear metres. Base stock and price remain explicit. Never round a customer's area request up silently.
- Returns preserve saved source-line conversion and net price. New-format server return validation caps quantity and source price.
- Offline saved records queue for sync. Another disconnected device can use old offers/prices until it reconnects. Scheduled dates still use the device clock.

## Storefront boundary

The existing oils store.html URL stays the default. Other shops get store.html?shop=<tenant UUID> from their own settings/share action. Public catalog reads call get_store with one explicit target and receive only whitelisted customer-facing fields. No tenant directory, costs, owner names, staff, customer data, orders or mobile-device identifiers are returned. Inactive/expired/unknown shops do not fall back to another shop. Carts are isolated by tenant; the original oils cart key is retained.

Round20 restricts anonymous raw shop settings and uses a safe function instead. Deploy the app and this SQL as a paired release; an old cached store page should be refreshed after rollout.

## SQL prerequisite

Review and apply `mahal-round19-commerce.sql`, then `mahal-round20-tenant-stores.sql`, before any later deployment. It adds Offers/RLS/public-safe views, unit configuration, order quote validation, configured-unit precision and source-return checks. It retains the existing tenant helper contracts. Live definitions were checked against the baseline before applying the approved migrations.

Apply the migration before the new app can write its new table. An unknown-table error would otherwise hold the offline queue. Older clients should update before returning a new-format invoice.

## Build

`python3 build-commerce.py` rebuilds the inline mobile/commerce sections in index.html and the shared store pricing section in store.html. Keep source files and their inline copies together. Do not include node_modules in any new commit.

## Tests

From test/: `npm ci` for the test-only dependencies. Then from repository root:

- `node test/harness.js`, original regression harness.
- `node test/commerce-core.js`, pure pricing/conversion checks.
- `node test/commerce-sql.cjs`, local PostgreSQL (PGlite) schema/RLS/order/precision/return checks. It never contacts Supabase.
- `node test/commerce-browser.js`, real local app/store UI with intercepted fixture backend, offline queue and second-device pull. Requires Chrome at /usr/bin/google-chrome. Images default to /tmp/mahal-commerce-shots, override with COMMERCE_SHOTS.

Additional local mobile suites cover warranty + Offers, installments, repair, queue replay and second-device pull. Legacy oils invoice and printed HTML were compared byte-for-byte against warranty commit 9b8e872, with identical output for unchanged legacy fixtures.

## Approved rollout

1. Preserve the current production commit and database function/policy definitions for recovery. Do not delete business or TEST records.
2. Apply round19, then round20 SQL in order. Verify RLS, both-store public-safe results and order tenant checks.
3. Publish index.html, store.html and sw.js to the two existing free origins. Source files (mobmod.src.js, commerce-core.src.js, commerce.src.js, store-commerce.src.js), build-commerce.py, SQL proposals, test code/dependency manifests, .gitignore and this note travel in the repository. Do not commit node_modules. No admin.html, hosting-plan, domain, photo-flow or legacy invoice-layout change.
4. Smoke-test the original oils URL, a mobile-shop tenant URL, tenant-specific offers/units, offline queue reconnect and separate warranties. Test orders require an explicitly identified test tenant, never a real shop's order queue.
5. Check both deployed versions and revoke any temporary deployment credentials, verifying revocation.

The separately approved sw.js fix (v40) prevents storefront/admin HTML from overwriting the owner app offline shell. The owner shell is precached, and offline non-owner HTML shows a connection notice rather than another page. test/store-sw-browser.cjs covers this path.
