-- ============================================================
-- محلّي — الجولة ١٣: تعدد المحلات (multi-tenant)
-- ⚠️ NOT applied yet. Apply only after plan approval.
-- Safe-by-design: existing shop becomes tenant #1 and keeps
-- working unchanged; every policy is tenant-scoped.
-- ============================================================

-- ---------- 1. جدول المحلات (المستأجرين) ----------
create table if not exists public.tenants(
  id uuid primary key default gen_random_uuid(),
  name text not null,                 -- اسم المحل
  slug text unique,                   -- لرابط المتجر الإلكتروني لاحقًا
  owner_name text default '',
  phone text default '',
  status text not null default 'active' check (status in ('active','suspended')),
  sub_start date,
  sub_end date,                       -- نهاية الاشتراك (null = مفتوح)
  notes text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- مالك المنصة (إسماعيل) — منفصل عن مستخدمي أي محل
create table if not exists public.platform_admins(
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------- 2. ربط المستخدمين بالمحلات ----------
alter table public.shop_users add column if not exists tenant_id uuid references public.tenants(id);

-- ---------- 3. دوال مساعدة (security definer = تقرأ shop_users بأمان) ----------
create or replace function public.my_tenant() returns uuid
language sql stable security definer set search_path=public as $$
  select tenant_id from public.shop_users
  where auth_id = auth.uid() and active limit 1
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

-- has_shop_perm يفضل زي ما هو: مستخدم واحد = محل واحد، فهو بالفعل مقيّد بالمحل

-- ---------- 4. tenant_id على كل جداول البيانات ----------
-- (شغّل الباك-فيل أول مرة بقيمة محل البركة، بعدين اقفل NOT NULL)
do $$
declare t text;
  data_tables text[] := array[
    'products','customers','suppliers','invoices','purchases','payments',
    'movements','expenses','sales_returns','service_txns','day_closes',
    'drawer_entries','counters','shop_info','backups','pin_attempts','orders','products_public'];
begin
  foreach t in array data_tables loop
    execute format('alter table public.%I add column if not exists tenant_id uuid references public.tenants(id)', t);
    execute format('create index if not exists %I on public.%I(tenant_id)', t||'_tenant_idx', t);
  end loop;
end $$;

-- ---------- 5. تسجيل محل البركة كأول مستأجر + باك-فيل ----------
-- ⚠️ شغّل القسم ده مرة واحدة بس. بعده NOT NULL + default.
insert into public.tenants (name, owner_name, phone, status, sub_start, sub_end)
select 'محل البركة', 'صاحب المحل', '', 'active', current_date, null
where not exists (select 1 from public.tenants);

-- ربط كل البيانات الحالية بمحل البركة
do $$
declare t text; tid uuid;
  data_tables text[] := array[
    'products','customers','suppliers','invoices','purchases','payments',
    'movements','expenses','sales_returns','service_txns','day_closes',
    'drawer_entries','counters','shop_info','backups','pin_attempts','orders','products_public'];
begin
  select id into tid from public.tenants order by created_at limit 1;
  foreach t in array data_tables loop
    execute format('update public.%I set tenant_id = $1 where tenant_id is null', t) using tid;
  end loop;
  update public.shop_users set tenant_id = tid where tenant_id is null;
end $$;

-- بعد التأكد من الباك-فيل: اقفل الإلزام + خلي الإدخال التلقائي من الدالة
-- do $$
-- declare t text;
--   data_tables text[] := array['products','customers','suppliers','invoices','purchases','payments',
--     'movements','expenses','sales_returns','service_txns','day_closes',
--     'drawer_entries','counters','shop_info','backups','pin_attempts','orders','products_public'];
-- begin
--   foreach t in array data_tables loop
--     execute format('alter table public.%I alter column tenant_id set not null', t);
--     execute format('alter table public.%I alter column tenant_id set default public.my_tenant()', t);
--   end loop;
--   alter table public.shop_users alter column tenant_id set not null;
-- end $$;

-- ---------- 6. صلاحيات RLS: كل محل يشوف بياناته بس ----------
-- القاعدة: قراءة = نفس المحل. كتابة = نفس المحل + البرميشن + الاشتراك فعّال.
-- مثال products — نفس النمط بيتكرر على الباقي:
drop policy if exists "member read products" on public.products;
drop policy if exists "perm write products" on public.products;
drop policy if exists "perm update products" on public.products;
drop policy if exists "perm delete products" on public.products;
create policy "tenant read products" on public.products for select to authenticated
  using (tenant_id = public.my_tenant());
create policy "tenant write products" on public.products for insert to authenticated
  with check (tenant_id = public.my_tenant() and public.has_shop_perm('products') and public.tenant_active());
create policy "tenant update products" on public.products for update to authenticated
  using (tenant_id = public.my_tenant() and public.has_shop_perm('products') and public.tenant_active())
  with check (tenant_id = public.my_tenant() and public.has_shop_perm('products') and public.tenant_active());
create policy "tenant delete products" on public.products for delete to authenticated
  using (tenant_id = public.my_tenant() and public.has_shop_perm('del') and public.tenant_active());

-- TODO عند التنفيذ: نفس الاستبدال لكل الجداول (customers, suppliers, invoices,
-- purchases, payments, movements, expenses, sales_returns, service_txns,
-- day_closes, drawer_entries, counters, shop_info, backups, pin_attempts)
-- بالـ perm المناسب لكل جدول زي الموجود حاليًا بالظبط بس + tenant_id + tenant_active.

-- shop_users: المستخدم يشوف زمايله في نفس المحل؛ صاحب المحل يديرهم
drop policy if exists "member read shop_users" on public.shop_users;
create policy "tenant read shop_users" on public.shop_users for select to authenticated
  using (tenant_id = public.my_tenant() or public.is_platform_admin());
-- (سياسات الكتابة الحالية على shop_users تتنقل بنفس الإضافة)

-- tenants: كل مستخدم يشوف محله؛ الأدمن يشوف الكل
alter table public.tenants enable row level security;
create policy "member read own tenant" on public.tenants for select to authenticated
  using (id = public.my_tenant() or public.is_platform_admin());
create policy "admin write tenants" on public.tenants for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

alter table public.platform_admins enable row level security;
create policy "admin read admins" on public.platform_admins for select to authenticated
  using (public.is_platform_admin());

-- ---------- 7. أوامر الأدمن (RPC) ----------
create or replace function public.admin_list_tenants()
returns table(id uuid, name text, owner_name text, phone text, status text,
              sub_start date, sub_end date, users bigint, products bigint,
              invoices_month bigint, last_activity timestamptz)
language sql stable security definer set search_path=public as $$
  select t.id, t.name, t.owner_name, t.phone, t.status, t.sub_start, t.sub_end,
    (select count(*) from shop_users su where su.tenant_id=t.id),
    (select count(*) from products p where p.tenant_id=t.id and not p.deleted),
    (select count(*) from invoices i where i.tenant_id=t.id
       and i.date >= date_trunc('month', now())),
    (select greatest((select max(i.date) from invoices i where i.tenant_id=t.id),
                     (select max(p.updated_at) from products p where p.tenant_id=t.id)))
  from tenants t
  where public.is_platform_admin()
  order by t.created_at;
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
  set sub_end = (greatest(coalesce(sub_end, current_date), current_date)
                 + (p_months||' months')::interval)::date,
      sub_start = coalesce(sub_start, current_date),
      status='active', updated_at=now()
  where id=p_tenant returning sub_end into new_end;
  return new_end;
end $$;

-- ---------- 8. إنشاء محل جديد ----------
-- إنشاء حساب الدخول (auth.users) محتاج service role → Edge Function
-- supabase/functions/admin-create-shop/index.ts (موجود في الريبو).
-- الـ function بتعمل: auth.admin.createUser + insert tenant + insert shop_users(owner).

-- ---------- 9. ملاحظات التخزين (الصور) ----------
-- دلوقتي: product-photos/<productId>.jpg — الـ ids عشوائية فمفيش تصادم بين المحلات.
-- المرحلة الجاية: product-photos/<tenant_id>/<productId>.jpg + policy على storage.objects:
--   using ((storage.foldername(name))[1] = public.my_tenant()::text)
-- المتجر العام (products_public + orders): يتقفل بـ slug بتاع المحل في المرحلة الجاية.
