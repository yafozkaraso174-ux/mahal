-- ============================================================
-- محلّي — الجولة ١٣: تعدد المحلات (multi-tenant) — APPLY TO LIVE
-- محل البركة = المستأجر رقم ١، وكل بياناته بتفضل شغالة زي ما هي.
-- ============================================================

-- ---------- 1. المحلات + أدمن المنصة ----------
create table if not exists public.tenants(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique,
  owner_name text default '',
  phone text default '',
  status text not null default 'active' check (status in ('active','suspended')),
  sub_start date,
  sub_end date,
  notes text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.platform_admins(
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------- 2. الدوال المساعدة ----------
create or replace function public.my_tenant() returns uuid
language sql stable security definer set search_path=public as $$
  select tenant_id from public.shop_users where auth_id = auth.uid() and active limit 1
$$;
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path=public as $$
  select coalesce(exists(select 1 from public.platform_admins where user_id = auth.uid()), false)
$$;
create or replace function public.tenant_active() returns boolean
language sql stable security definer set search_path=public as $$
  select coalesce((select t.status='active' and (t.sub_end is null or t.sub_end >= current_date)
                   from public.tenants t where t.id = public.my_tenant()), false)
$$;

-- ---------- 3. tenant_id على كل الجداول ----------
alter table public.shop_users add column if not exists tenant_id uuid references public.tenants(id);
do $$
declare t text;
  data_tables text[] := array[
    'products','customers','suppliers','invoices','purchases','payments',
    'movements','expenses','sales_returns','service_txns','day_closes',
    'drawer_entries','counters','shop_info','backups','orders'];
begin
  foreach t in array data_tables loop
    execute format('alter table public.%I add column if not exists tenant_id uuid references public.tenants(id)', t);
    execute format('create index if not exists %I on public.%I(tenant_id)', t||'_tenant_idx', t);
  end loop;
end $$;

-- ---------- 4. محل البركة = tenant 1 + باك-فيل ----------
insert into public.tenants (name, owner_name, phone, status, sub_start, sub_end)
select 'محل البركة', 'صاحب المحل', '', 'active', current_date, null
where not exists (select 1 from public.tenants);

insert into public.platform_admins (user_id)
select id from auth.users where email='yafozkaraso174@gmail.com'
on conflict do nothing;

do $$
declare t text; tid uuid;
  data_tables text[] := array[
    'products','customers','suppliers','invoices','purchases','payments',
    'movements','expenses','sales_returns','service_txns','day_closes',
    'drawer_entries','counters','shop_info','backups','orders'];
begin
  select id into tid from public.tenants order by created_at limit 1;
  foreach t in array data_tables loop
    execute format('update public.%I set tenant_id = $1 where tenant_id is null', t) using tid;
  end loop;
  update public.shop_users set tenant_id = tid where tenant_id is null;
end $$;

-- ---------- 5. الإلزام + الافتراضي (الجداول الداخلية) ----------
do $$
declare t text;
  internal_tables text[] := array[
    'products','customers','suppliers','invoices','purchases','payments',
    'movements','expenses','sales_returns','service_txns','day_closes',
    'drawer_entries','counters','shop_info','backups'];
begin
  foreach t in array internal_tables loop
    execute format('alter table public.%I alter column tenant_id set default public.my_tenant()', t);
    execute format('alter table public.%I alter column tenant_id set not null', t);
  end loop;
  alter table public.shop_users alter column tenant_id set not null;
  -- orders: nullable لحد ما المتجر يبعت tenant_id صراحة (store.html)
  alter table public.orders alter column tenant_id set default public.my_tenant();
  -- products_public: view — نعيد بناءها ومعاها tenant_id (مرحلة المتجر: فلترة بيها)
  drop view if exists public.products_public;
  create view public.products_public as
    select tenant_id, id, name, cat, unit, price, stock, photo_url
    from public.products where deleted = false;
end $$;

-- ---------- 6. المفاتيح المركبة (counters + shop_info) ----------
alter table public.counters drop constraint if exists counters_pkey;
alter table public.counters add primary key (tenant_id, id);
alter table public.shop_info drop constraint if exists shop_info_pkey;
alter table public.shop_info add primary key (tenant_id, id);

-- ---------- 7. العدادات لكل محل ----------
create or replace function public.next_invoice_num() returns bigint
language plpgsql security definer set search_path=public as $$
declare v bigint; t uuid := public.my_tenant();
begin
  insert into public.counters (tenant_id, id, val) values (t, 'invoice_num', 1000) on conflict (tenant_id, id) do nothing;
  update public.counters set val = val + 1 where tenant_id = t and id = 'invoice_num' returning val into v;
  return v;
end $$;
create or replace function public.next_return_num() returns bigint
language plpgsql security definer set search_path=public as $$
declare v bigint; t uuid := public.my_tenant();
begin
  insert into public.counters (tenant_id, id, val) values (t, 'return_num', 0) on conflict (tenant_id, id) do nothing;
  update public.counters set val = val + 1 where tenant_id = t and id = 'return_num' returning val into v;
  return v;
end $$;
create or replace function public.set_invoice_counter(v bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_shop_owner() then raise exception 'no permission'; end if;
  insert into public.counters (tenant_id, id, val) values (public.my_tenant(), 'invoice_num', v)
  on conflict (tenant_id, id) do update set val = greatest(public.counters.val, excluded.val);
end $$;

-- ---------- 8. RLS: سياسات مقفولة بالمحل ----------
-- ماكرو-ستايل: لكل جدول — قراءة بنفس شروط النهارده + tenant، وكتابة + tenant_active.

-- products / customers / suppliers / movements: قراءة أي عضو
drop policy if exists "member read products" on public.products;
drop policy if exists "perm write products" on public.products;
drop policy if exists "perm update products" on public.products;
drop policy if exists "perm delete products" on public.products;
create policy "tenant read products" on public.products for select to authenticated using (tenant_id = public.my_tenant());
create policy "tenant write products" on public.products for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('products') and public.tenant_active());
create policy "tenant update products" on public.products for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('products') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('products') and public.tenant_active());
create policy "tenant delete products" on public.products for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "member read customers" on public.customers;
drop policy if exists "perm write customers" on public.customers;
drop policy if exists "perm update customers" on public.customers;
drop policy if exists "perm delete customers" on public.customers;
create policy "tenant read customers" on public.customers for select to authenticated using (tenant_id = public.my_tenant());
create policy "tenant write customers" on public.customers for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('customers') and public.tenant_active());
create policy "tenant update customers" on public.customers for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('customers') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('customers') and public.tenant_active());
create policy "tenant delete customers" on public.customers for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "member read suppliers" on public.suppliers;
drop policy if exists "perm write suppliers" on public.suppliers;
drop policy if exists "perm update suppliers" on public.suppliers;
drop policy if exists "perm delete suppliers" on public.suppliers;
create policy "tenant read suppliers" on public.suppliers for select to authenticated using (tenant_id = public.my_tenant());
create policy "tenant write suppliers" on public.suppliers for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('suppliers') and public.tenant_active());
create policy "tenant update suppliers" on public.suppliers for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('suppliers') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('suppliers') and public.tenant_active());
create policy "tenant delete suppliers" on public.suppliers for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "member read movements" on public.movements;
drop policy if exists "member write movements" on public.movements;
create policy "tenant read movements" on public.movements for select to authenticated using (tenant_id = public.my_tenant());
create policy "tenant write movements" on public.movements for insert to authenticated with check (tenant_id = public.my_tenant() and public.tenant_active());

-- invoices / sales_returns / service_txns: قراءة invoice أو stats
drop policy if exists "perm read invoices" on public.invoices;
drop policy if exists "perm write invoices" on public.invoices;
drop policy if exists "perm update invoices" on public.invoices;
drop policy if exists "perm delete invoices" on public.invoices;
create policy "tenant read invoices" on public.invoices for select to authenticated using (tenant_id = public.my_tenant() and (public.has_shop_perm('invoice') or public.has_shop_perm('stats')));
create policy "tenant write invoices" on public.invoices for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active());
create policy "tenant update invoices" on public.invoices for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active());
create policy "tenant delete invoices" on public.invoices for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "perm read returns" on public.sales_returns;
drop policy if exists "perm write returns" on public.sales_returns;
drop policy if exists "perm update returns" on public.sales_returns;
drop policy if exists "perm delete returns" on public.sales_returns;
create policy "tenant read returns" on public.sales_returns for select to authenticated using (tenant_id = public.my_tenant() and (public.has_shop_perm('invoice') or public.has_shop_perm('stats')));
create policy "tenant write returns" on public.sales_returns for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active());
create policy "tenant update returns" on public.sales_returns for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active());
create policy "tenant delete returns" on public.sales_returns for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "perm read service_txns" on public.service_txns;
drop policy if exists "perm write service_txns" on public.service_txns;
drop policy if exists "perm update service_txns" on public.service_txns;
drop policy if exists "perm delete service_txns" on public.service_txns;
create policy "tenant read service_txns" on public.service_txns for select to authenticated using (tenant_id = public.my_tenant() and (public.has_shop_perm('invoice') or public.has_shop_perm('stats')));
create policy "tenant write service_txns" on public.service_txns for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active());
create policy "tenant update service_txns" on public.service_txns for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('invoice') and public.tenant_active());
create policy "tenant delete service_txns" on public.service_txns for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

-- purchases: قراءة suppliers أو stats
drop policy if exists "perm read purchases" on public.purchases;
drop policy if exists "perm write purchases" on public.purchases;
drop policy if exists "perm update purchases" on public.purchases;
drop policy if exists "perm delete purchases" on public.purchases;
create policy "tenant read purchases" on public.purchases for select to authenticated using (tenant_id = public.my_tenant() and (public.has_shop_perm('suppliers') or public.has_shop_perm('stats')));
create policy "tenant write purchases" on public.purchases for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('suppliers') and public.tenant_active());
create policy "tenant update purchases" on public.purchases for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('suppliers') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('suppliers') and public.tenant_active());
create policy "tenant delete purchases" on public.purchases for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

-- payments
drop policy if exists "perm read payments" on public.payments;
drop policy if exists "perm write payments" on public.payments;
drop policy if exists "perm update payments" on public.payments;
drop policy if exists "perm delete payments" on public.payments;
create policy "tenant read payments" on public.payments for select to authenticated using (tenant_id = public.my_tenant() and (public.has_shop_perm('invoice') or public.has_shop_perm('customers') or public.has_shop_perm('suppliers') or public.has_shop_perm('stats')));
create policy "tenant write payments" on public.payments for insert to authenticated with check (tenant_id = public.my_tenant() and (public.has_shop_perm('invoice') or public.has_shop_perm('customers') or public.has_shop_perm('suppliers')) and public.tenant_active());
create policy "tenant delete payments" on public.payments for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

-- expenses / day_closes / drawer_entries: stats
drop policy if exists "perm read expenses" on public.expenses;
drop policy if exists "perm write expenses" on public.expenses;
drop policy if exists "perm update expenses" on public.expenses;
drop policy if exists "perm delete expenses" on public.expenses;
create policy "tenant read expenses" on public.expenses for select to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('stats'));
create policy "tenant write expenses" on public.expenses for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active());
create policy "tenant update expenses" on public.expenses for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active());
create policy "tenant delete expenses" on public.expenses for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "perm read day_closes" on public.day_closes;
drop policy if exists "perm write day_closes" on public.day_closes;
drop policy if exists "perm update day_closes" on public.day_closes;
drop policy if exists "perm delete day_closes" on public.day_closes;
create policy "tenant read day_closes" on public.day_closes for select to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('stats'));
create policy "tenant write day_closes" on public.day_closes for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active());
create policy "tenant update day_closes" on public.day_closes for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active());
create policy "tenant delete day_closes" on public.day_closes for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

drop policy if exists "perm read drawer" on public.drawer_entries;
drop policy if exists "perm write drawer" on public.drawer_entries;
drop policy if exists "perm update drawer" on public.drawer_entries;
drop policy if exists "perm delete drawer" on public.drawer_entries;
create policy "tenant read drawer" on public.drawer_entries for select to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('stats'));
create policy "tenant write drawer" on public.drawer_entries for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active());
create policy "tenant update drawer" on public.drawer_entries for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('stats') and public.tenant_active());
create policy "tenant delete drawer" on public.drawer_entries for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

-- shop_info: المتجر العام يقرا محل البركة بس + العضو يقرا محله + كتابة settings
drop policy if exists "public read shop_info" on public.shop_info;
drop policy if exists "perm write shop_info" on public.shop_info;
drop policy if exists "perm update shop_info" on public.shop_info;
drop policy if exists "perm delete shop_info" on public.shop_info;
create policy "public read store shop_info" on public.shop_info for select to anon, authenticated
  using (tenant_id = (select id from public.tenants order by created_at limit 1)
         or tenant_id = public.my_tenant());
create policy "tenant write shop_info" on public.shop_info for insert to authenticated with check (tenant_id = public.my_tenant() and public.has_shop_perm('settings') and public.tenant_active());
create policy "tenant update shop_info" on public.shop_info for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('settings') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('settings') and public.tenant_active());
create policy "tenant delete shop_info" on public.shop_info for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('settings') and public.tenant_active());

-- counters: الوصول عن طريق الـ RPCs بس
alter table public.counters enable row level security;

-- backups: المالك بس في محله
drop policy if exists "owner all backups" on public.backups;
create policy "tenant owner backups" on public.backups for all to authenticated
  using (tenant_id = public.my_tenant() and public.is_shop_owner())
  with check (tenant_id = public.my_tenant() and public.is_shop_owner());

-- orders: قراءة/تعديل ببرميشن orders في نفس المحل + إدخال عام (المتجر)
drop policy if exists "perm read orders" on public.orders;
drop policy if exists "perm update orders" on public.orders;
drop policy if exists "perm delete orders" on public.orders;
create policy "tenant read orders" on public.orders for select to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('orders'));
create policy "tenant update orders" on public.orders for update to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('orders') and public.tenant_active()) with check (tenant_id = public.my_tenant() and public.has_shop_perm('orders') and public.tenant_active());
create policy "tenant delete orders" on public.orders for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());
-- (public insert orders يفضل زي ما هو)

-- shop_users: شوف نفسك + المالك يشوف/يدير محله + أدمن المنصة
drop policy if exists "read own shop_users" on public.shop_users;
drop policy if exists "owner write shop_users" on public.shop_users;
create policy "tenant read shop_users" on public.shop_users for select to authenticated
  using (auth_id = auth.uid() or (tenant_id = public.my_tenant() and public.is_shop_owner()) or public.is_platform_admin());
create policy "tenant owner write shop_users" on public.shop_users for insert to authenticated
  with check ((tenant_id = public.my_tenant() and public.is_shop_owner()) or public.is_platform_admin());
create policy "tenant owner update shop_users" on public.shop_users for update to authenticated
  using ((tenant_id = public.my_tenant() and public.is_shop_owner()) or public.is_platform_admin())
  with check ((tenant_id = public.my_tenant() and public.is_shop_owner()) or public.is_platform_admin());
create policy "tenant owner delete shop_users" on public.shop_users for delete to authenticated
  using ((tenant_id = public.my_tenant() and public.is_shop_owner()) or public.is_platform_admin());

-- tenants + platform_admins
alter table public.tenants enable row level security;
create policy "member read own tenant" on public.tenants for select to authenticated
  using (id = public.my_tenant() or public.is_platform_admin());
create policy "admin write tenants" on public.tenants for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());
alter table public.platform_admins enable row level security;
create policy "admin read admins" on public.platform_admins for select to authenticated
  using (public.is_platform_admin());

-- ---------- 9. أوامر الأدمن ----------
create or replace function public.admin_list_tenants()
returns table(id uuid, name text, owner_name text, phone text, status text,
              sub_start date, sub_end date, users bigint, products bigint,
              invoices_month bigint, last_activity timestamptz)
language sql stable security definer set search_path=public as $$
  select t.id, t.name, t.owner_name, t.phone, t.status, t.sub_start, t.sub_end,
    (select count(*) from shop_users su where su.tenant_id=t.id and su.active),
    (select count(*) from products p where p.tenant_id=t.id and not p.deleted),
    (select count(*) from invoices i where i.tenant_id=t.id and i.date >= date_trunc('month', now())),
    (select greatest((select max(i.updated_at) from invoices i where i.tenant_id=t.id),
                     (select max(p.updated_at) from products p where p.tenant_id=t.id)))
  from tenants t where public.is_platform_admin() order by t.created_at;
$$;
create or replace function public.admin_set_tenant_status(p_tenant uuid, p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_platform_admin() then raise exception 'not admin'; end if;
  if p_status not in ('active','suspended') then raise exception 'bad status'; end if;
  update tenants set status=p_status, updated_at=now() where id=p_tenant;
end $$;
create or replace function public.admin_extend_subscription(p_tenant uuid, p_months int)
returns date language plpgsql security definer set search_path=public as $$
declare new_end date;
begin
  if not public.is_platform_admin() then raise exception 'not admin'; end if;
  update tenants
  set sub_end = (greatest(coalesce(sub_end, current_date), current_date) + (p_months||' months')::interval)::date,
      sub_start = coalesce(sub_start, current_date), status='active', updated_at=now()
  where id=p_tenant returning sub_end into new_end;
  return new_end;
end $$;

-- ---------- 10. إصلاح قراءة المتجر العام (السياسة الفرعية كانت بتضرب في RLS) ----------
create or replace function public.store_tenant() returns uuid
language sql stable security definer set search_path=public as
$$ select id from public.tenants order by created_at limit 1 $$;
drop policy if exists "public read store shop_info" on public.shop_info;
create policy "public read store shop_info" on public.shop_info for select to anon, authenticated
  using (tenant_id = public.store_tenant() or tenant_id = public.my_tenant());
