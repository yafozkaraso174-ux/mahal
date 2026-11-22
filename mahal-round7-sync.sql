-- ============================================================
-- محلّي — جولة ٧ (٢٠٢٦-١١-٢٢): مزامنة شغل الموظفين + صلاحيات على مستوى القاعدة
-- بتحوّل البيانات المشتركة (زباين/موردين/فواتير/توريدات/دفعات/حركة مخزون)
-- لجداول حقيقية صف-صف، وبتطبّق صلاحيات كل موظف على السيرفر نفسه.
-- بتشمل جولة ٦ (has_shop_perm + سياسات الصلاحيات) عشان ملف واحد بس هو المطلوب.
-- آمن يتشغل أكتر من مرة. في الآخر بيطبع نتيجة الفحص الذاتي.
-- ============================================================

-- ١) دوال الصلاحيات (security definer — مفيش أي grant جديد على auth.users)
create or replace function public.has_shop_perm(p text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(exists(
    select 1 from public.shop_users
    where auth_id = auth.uid() and active
      and (owner or coalesce((perms->>p)::boolean, false))
  ), false);
$$;
revoke all on function public.has_shop_perm(text) from public;
grant execute on function public.has_shop_perm(text) to anon, authenticated;

-- ٢) ترقية الجداول الموجودة
alter table public.products add column if not exists wprice numeric;
alter table public.products add column if not exists cost numeric;
alter table public.products add column if not exists lowat numeric not null default 0;
alter table public.products add column if not exists deleted boolean not null default false;

-- عرض عام للمتجر: من غير سعر الجملة ولا التكلفة
create or replace view public.products_public as
  select id, name, cat, unit, price, stock, photo_url
  from public.products
  where deleted = false;
grant select on public.products_public to anon, authenticated;

-- ٣) الجداول الجديدة (صف-صف)
create table if not exists public.customers (
  id text primary key,
  name text not null,
  phone text not null default '',
  type text not null default 'r',
  deleted boolean not null default false,
  created_by uuid,
  updated_at timestamptz not null default now()
);
create table if not exists public.suppliers (
  id text primary key,
  name text not null,
  phone text not null default '',
  deleted boolean not null default false,
  created_by uuid,
  updated_at timestamptz not null default now()
);
create table if not exists public.invoices (
  id text primary key,
  num bigint not null,
  date timestamptz not null default now(),
  customer_id text,
  price_type text not null default 'r',
  items jsonb not null default '[]',
  disc_pct numeric not null default 0,
  tax_pct numeric not null default 0,
  disc_amt numeric not null default 0,
  tax_amt numeric not null default 0,
  delivery_fee numeric not null default 0,
  total numeric not null default 0,
  paid numeric not null default 0,
  credit_used numeric not null default 0,
  created_by uuid,
  updated_at timestamptz not null default now()
);
create unique index if not exists invoices_num_key on public.invoices (num);
create index if not exists invoices_updated_idx on public.invoices (updated_at);
create table if not exists public.purchases (
  id text primary key,
  date timestamptz not null default now(),
  supplier_id text,
  items jsonb not null default '[]',
  total numeric not null default 0,
  paid numeric not null default 0,
  created_by uuid,
  updated_at timestamptz not null default now()
);
create index if not exists purchases_updated_idx on public.purchases (updated_at);
create table if not exists public.payments (
  id text primary key,
  date timestamptz not null default now(),
  kind text not null,
  party_type text not null,
  party_id text not null,
  amount numeric not null default 0,
  note text not null default '',
  created_by uuid,
  inserted_at timestamptz not null default now()
);
create index if not exists payments_inserted_idx on public.payments (inserted_at);
create table if not exists public.movements (
  id text primary key,
  pid text not null,
  kind text not null,
  qty numeric not null,
  qty_before numeric,
  qty_after numeric,
  ref text not null default '',
  date timestamptz not null default now(),
  created_by uuid,
  inserted_at timestamptz not null default now()
);
create index if not exists movements_inserted_idx on public.movements (inserted_at);
create index if not exists movements_pid_idx on public.movements (pid);
create table if not exists public.counters (
  id text primary key,
  val bigint not null
);
insert into public.counters (id, val) values ('invoice_num', 1000) on conflict (id) do nothing;

-- ٤) تحديث updated_at أوتوماتيك
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists touch_products on public.products;
create trigger touch_products before update on public.products for each row execute function public.touch_updated_at();
drop trigger if exists touch_customers on public.customers;
create trigger touch_customers before update on public.customers for each row execute function public.touch_updated_at();
drop trigger if exists touch_suppliers on public.suppliers;
create trigger touch_suppliers before update on public.suppliers for each row execute function public.touch_updated_at();
drop trigger if exists touch_invoices on public.invoices;
create trigger touch_invoices before update on public.invoices for each row execute function public.touch_updated_at();
drop trigger if exists touch_purchases on public.purchases;
create trigger touch_purchases before update on public.purchases for each row execute function public.touch_updated_at();

-- ٥) سياسات الأمان: كل صلاحية بتتفرض على السيرفر
alter table public.customers enable row level security;
alter table public.suppliers enable row level security;
alter table public.invoices enable row level security;
alter table public.purchases enable row level security;
alter table public.payments enable row level security;
alter table public.movements enable row level security;
alter table public.counters enable row level security;

-- shop_users: كل عضو يقرأ صفه بس، المالك يقرأ ويكتب الكل
drop policy if exists "member read shop_users" on public.shop_users;
create policy "read own shop_users" on public.shop_users for select to authenticated
  using (auth_id = auth.uid() or public.is_shop_owner());

-- الأصناف: الأعضاء يقرأوا، التعديل بصلاحية "الأصناف"
drop policy if exists "member all products" on public.products;
drop policy if exists "public read products" on public.products;
create policy "member read products" on public.products for select to authenticated
  using (public.is_shop_member());
create policy "perm write products" on public.products for insert to authenticated
  with check (public.has_shop_perm('products'));
create policy "perm update products" on public.products for update to authenticated
  using (public.has_shop_perm('products')) with check (public.has_shop_perm('products'));
create policy "perm delete products" on public.products for delete to authenticated
  using (public.has_shop_perm('products'));

-- طلبات المتجر: قراءة وتعديل بصلاحية "طلبات المتجر"، الإرسال من الزباين زي ما هو
drop policy if exists "member all orders" on public.orders;
create policy "perm read orders" on public.orders for select to authenticated
  using (public.has_shop_perm('orders'));
create policy "perm update orders" on public.orders for update to authenticated
  using (public.has_shop_perm('orders')) with check (public.has_shop_perm('orders'));
create policy "perm delete orders" on public.orders for delete to authenticated
  using (public.has_shop_perm('orders'));

-- بيانات المحل (المتجر): القراءة عامة، التعديل بصلاحية "الإعدادات"
drop policy if exists "member all shop_info" on public.shop_info;
create policy "perm write shop_info" on public.shop_info for insert to authenticated
  with check (public.has_shop_perm('settings'));
create policy "perm update shop_info" on public.shop_info for update to authenticated
  using (public.has_shop_perm('settings')) with check (public.has_shop_perm('settings'));
create policy "perm delete shop_info" on public.shop_info for delete to authenticated
  using (public.has_shop_perm('settings'));

-- صور الأصناف: الرفع بصلاحية "الأصناف"
drop policy if exists "member write product photos" on storage.objects;
create policy "perm write product photos" on storage.objects for all to authenticated
  using (bucket_id = 'product-photos' and public.has_shop_perm('products'))
  with check (bucket_id = 'product-photos' and public.has_shop_perm('products'));

-- الزباين: قراءة لكل الأعضاء، تعديل بصلاحية "الزباين"
drop policy if exists "member read customers" on public.customers;
create policy "member read customers" on public.customers for select to authenticated
  using (public.is_shop_member());
drop policy if exists "perm write customers" on public.customers;
create policy "perm write customers" on public.customers for insert to authenticated
  with check (public.has_shop_perm('customers'));
drop policy if exists "perm update customers" on public.customers;
create policy "perm update customers" on public.customers for update to authenticated
  using (public.has_shop_perm('customers')) with check (public.has_shop_perm('customers'));
drop policy if exists "perm delete customers" on public.customers;
create policy "perm delete customers" on public.customers for delete to authenticated
  using (public.has_shop_perm('customers'));

-- الموردين: قراءة لكل الأعضاء، تعديل بصلاحية "الموردين"
create policy "member read suppliers" on public.suppliers for select to authenticated
  using (public.is_shop_member());
create policy "perm write suppliers" on public.suppliers for insert to authenticated
  with check (public.has_shop_perm('suppliers'));
create policy "perm update suppliers" on public.suppliers for update to authenticated
  using (public.has_shop_perm('suppliers')) with check (public.has_shop_perm('suppliers'));
create policy "perm delete suppliers" on public.suppliers for delete to authenticated
  using (public.has_shop_perm('suppliers'));

-- الفواتير: قراءة بصلاحية "فواتير" أو "إحصائيات"، تعديل بـ "فواتير"، مسح بـ "مسح بيانات"
create policy "perm read invoices" on public.invoices for select to authenticated
  using (public.has_shop_perm('invoice') or public.has_shop_perm('stats'));
create policy "perm write invoices" on public.invoices for insert to authenticated
  with check (public.has_shop_perm('invoice'));
create policy "perm update invoices" on public.invoices for update to authenticated
  using (public.has_shop_perm('invoice')) with check (public.has_shop_perm('invoice'));
create policy "perm delete invoices" on public.invoices for delete to authenticated
  using (public.has_shop_perm('del'));

-- التوريدات: قراءة بـ "موردين" أو "إحصائيات"، تعديل بـ "موردين"، مسح بـ "مسح بيانات"
create policy "perm read purchases" on public.purchases for select to authenticated
  using (public.has_shop_perm('suppliers') or public.has_shop_perm('stats'));
create policy "perm write purchases" on public.purchases for insert to authenticated
  with check (public.has_shop_perm('suppliers'));
create policy "perm update purchases" on public.purchases for update to authenticated
  using (public.has_shop_perm('suppliers')) with check (public.has_shop_perm('suppliers'));
create policy "perm delete purchases" on public.purchases for delete to authenticated
  using (public.has_shop_perm('del'));

-- الدفعات: قراءة لأي حد عنده صلاحية مرتبطة، تسجيل بنفس الصلاحيات، مسح بـ "مسح بيانات"
create policy "perm read payments" on public.payments for select to authenticated
  using (public.has_shop_perm('invoice') or public.has_shop_perm('customers')
      or public.has_shop_perm('suppliers') or public.has_shop_perm('stats'));
create policy "perm write payments" on public.payments for insert to authenticated
  with check (public.has_shop_perm('invoice') or public.has_shop_perm('customers')
      or public.has_shop_perm('suppliers'));
create policy "perm delete payments" on public.payments for delete to authenticated
  using (public.has_shop_perm('del'));

-- حركة المخزون: قراءة وتسجيل لكل الأعضاء (المخزون نفسه محمي بصلاحية الأصناف)
create policy "member read movements" on public.movements for select to authenticated
  using (public.is_shop_member());
create policy "member write movements" on public.movements for insert to authenticated
  with check (public.is_shop_member());

-- العدادات: ممنوعة تماماً من الخارج — بتشتغل عن طريق الدوال بس

-- ٦) دوال الحفظ الذرية (بتفحص الصلاحية جواها + بتخصم/تزود المخزون في نفس العملية)
create or replace function public.next_invoice_num() returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.counters (id, val) values ('invoice_num', 1000) on conflict (id) do nothing;
  update public.counters set val = val + 1 where id = 'invoice_num' returning val into v;
  return v;
end $$;

create or replace function public.set_invoice_counter(v bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_shop_owner() then raise exception 'no permission'; end if;
  insert into public.counters (id, val) values ('invoice_num', v)
  on conflict (id) do update set val = greatest(public.counters.val, excluded.val);
end $$;

create or replace function public.save_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_cust text := nullif(p->>'customerId','');
  v_item jsonb;
  v_pid text; v_qty numeric; v_stock numeric; v_before numeric; v_name text;
  v_short text := '';
  v_num bigint;
  v_inv public.invoices%rowtype;
  v_credit numeric := coalesce((p->>'creditUsed')::numeric, 0);
begin
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_inv from public.invoices where id = v_id;
    if found then return to_jsonb(v_inv); end if;  -- اتسجلت قبل كده (إعادة محاولة)
  end if;
  if v_cust is null or not exists(select 1 from public.customers where id = v_cust and deleted = false) then
    raise exception 'customer missing';
  end if;
  -- فحص المخزون مع قفل الصفوف
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_pid is not null then
      select stock, name into v_stock, v_name from public.products where id = v_pid for update;
      if found and v_qty > v_stock then
        v_short := v_short || coalesce(v_name, v_pid) || ' (متاح ' || trim(to_char(v_stock,'999990.##')) || ')، ';
      end if;
    end if;
  end loop;
  if v_short <> '' then raise exception 'shortage: %', left(v_short, -2); end if;
  -- خصم المخزون + تسجيل الحركة
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_pid is not null then
      select stock into v_before from public.products where id = v_pid;
      if found then
        update public.products set stock = round((stock - v_qty)::numeric, 2) where id = v_pid returning stock into v_stock;
        insert into public.movements (id, pid, kind, qty, qty_before, qty_after, ref, date, created_by)
        values (coalesce(nullif(v_item->>'moveId',''), gen_random_uuid()::text), v_pid, coalesce(nullif(v_item->>'moveKind',''),'sale'), -v_qty, v_before, v_stock, 'فاتورة', coalesce((p->>'date')::timestamptz, now()), auth.uid());
      end if;
    end if;
  end loop;
  v_num := public.next_invoice_num();
  insert into public.invoices (id, num, date, customer_id, price_type, items, disc_pct, tax_pct, disc_amt, tax_amt, delivery_fee, total, paid, credit_used, created_by)
  values (
    coalesce(v_id, gen_random_uuid()::text), v_num, coalesce((p->>'date')::timestamptz, now()), v_cust,
    coalesce(nullif(p->>'priceType',''),'r'), coalesce(p->'items','[]'::jsonb),
    coalesce((p->>'discPct')::numeric,0), coalesce((p->>'taxPct')::numeric,0),
    coalesce((p->>'discAmt')::numeric,0), coalesce((p->>'taxAmt')::numeric,0),
    coalesce((p->>'deliveryFee')::numeric,0), coalesce((p->>'total')::numeric,0),
    coalesce((p->>'paid')::numeric,0), v_credit, auth.uid())
  returning * into v_inv;
  update public.movements set ref = 'فاتورة #' || v_num where ref = 'فاتورة' and created_by = auth.uid() and date > now() - interval '1 minute' and pid in (select nullif(it->>'productId','') from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it);
  if v_credit > 0 then
    insert into public.payments (id, date, kind, party_type, party_id, amount, note, created_by)
    values (coalesce(nullif(p->>'creditPaymentId',''), gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), 'in', 'c', v_cust, -v_credit, 'خصم من رصيده في فاتورة #' || v_num, auth.uid())
    on conflict (id) do nothing;
  end if;
  return to_jsonb(v_inv);
end $$;

create or replace function public.save_purchase(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_supp text := nullif(p->>'supplierId','');
  v_item jsonb;
  v_pid text; v_qty numeric; v_cost numeric; v_stock numeric; v_before numeric;
  v_pur public.purchases%rowtype;
begin
  if not public.has_shop_perm('suppliers') then raise exception 'no permission: suppliers'; end if;
  if v_id is not null then
    select * into v_pur from public.purchases where id = v_id;
    if found then return to_jsonb(v_pur); end if;
  end if;
  if v_supp is null or not exists(select 1 from public.suppliers where id = v_supp and deleted = false) then
    raise exception 'supplier missing';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    v_cost := coalesce((v_item->>'cost')::numeric, 0);
    if v_pid is not null then
      select stock into v_before from public.products where id = v_pid for update;
      if found then
        update public.products set stock = round((stock + v_qty)::numeric, 2), cost = v_cost where id = v_pid returning stock into v_stock;
        insert into public.movements (id, pid, kind, qty, qty_before, qty_after, ref, date, created_by)
        values (coalesce(nullif(v_item->>'moveId',''), gen_random_uuid()::text), v_pid, 'in', v_qty, v_before, v_stock, 'توريد', coalesce((p->>'date')::timestamptz, now()), auth.uid());
      end if;
    end if;
  end loop;
  insert into public.purchases (id, date, supplier_id, items, total, paid, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), v_supp,
          coalesce(p->'items','[]'::jsonb), coalesce((p->>'total')::numeric,0), coalesce((p->>'paid')::numeric,0), auth.uid())
  returning * into v_pur;
  return to_jsonb(v_pur);
end $$;

create or replace function public.record_payment(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_kind text := coalesce(nullif(p->>'kind',''),'in');
  v_pay public.payments%rowtype;
begin
  if v_kind = 'in' then
    if not (public.has_shop_perm('invoice') or public.has_shop_perm('customers')) then raise exception 'no permission'; end if;
  else
    if not public.has_shop_perm('suppliers') then raise exception 'no permission'; end if;
  end if;
  if v_id is not null then
    select * into v_pay from public.payments where id = v_id;
    if found then return to_jsonb(v_pay); end if;
  end if;
  insert into public.payments (id, date, kind, party_type, party_id, amount, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), v_kind,
          coalesce(nullif(p->>'partyType',''), case when v_kind='in' then 'c' else 's' end),
          nullif(p->>'partyId',''), coalesce((p->>'amount')::numeric,0), coalesce(p->>'note',''), auth.uid())
  returning * into v_pay;
  return to_jsonb(v_pay);
end $$;

revoke all on function public.next_invoice_num() from public;
revoke all on function public.set_invoice_counter(bigint) from public;
grant execute on function public.set_invoice_counter(bigint) to authenticated;
revoke all on function public.save_invoice(jsonb) from public;
grant execute on function public.save_invoice(jsonb) to authenticated;
revoke all on function public.save_purchase(jsonb) from public;
grant execute on function public.save_purchase(jsonb) to authenticated;
revoke all on function public.record_payment(jsonb) from public;
grant execute on function public.record_payment(jsonb) to authenticated;

-- ٧) فحص ذاتي — لو في حاجة ناقصة هيطلع خطأ برسالة واضحة
do $$
begin
  if (select count(*) from information_schema.tables where table_schema='public'
      and table_name in ('customers','suppliers','invoices','purchases','payments','movements','counters')) < 7 then
    raise exception 'ROUND7 FAIL: ناقص جداول'; end if;
  if (select count(*) from information_schema.routines where routine_schema='public'
      and routine_name in ('has_shop_perm','save_invoice','save_purchase','record_payment','next_invoice_num','set_invoice_counter')) < 6 then
    raise exception 'ROUND7 FAIL: ناقص دوال'; end if;
  if (select count(*) from information_schema.columns where table_schema='public' and table_name='products'
      and column_name in ('wprice','cost','lowat','deleted')) < 4 then
    raise exception 'ROUND7 FAIL: أعمدة products ناقصة'; end if;
  if (select count(*) from information_schema.columns where table_schema='public' and table_name='products_public'
      and column_name in ('wprice','cost')) > 0 then
    raise exception 'ROUND7 FAIL: products_public بيسرّب أسعار داخلية'; end if;
  if not exists(select 1 from public.counters where id='invoice_num') then
    raise exception 'ROUND7 FAIL: العداد مش موجود'; end if;
  if (select count(*) from pg_policies where schemaname='public' and tablename='invoices') < 4 then
    raise exception 'ROUND7 FAIL: سياسات الفواتير ناقصة'; end if;
  raise notice 'ROUND7 PASS';
end $$;

-- نتيجة الفحص النهائية (لازم كل الأرقام تطابق أسماء الأعمدة)
select
  (select count(*) from information_schema.tables where table_schema='public' and table_name in ('customers','suppliers','invoices','purchases','payments','movements','counters')) as tables_7,
  (select count(*) from information_schema.routines where routine_schema='public' and routine_name in ('has_shop_perm','save_invoice','save_purchase','record_payment','next_invoice_num','set_invoice_counter')) as functions_6,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='products' and column_name in ('wprice','cost','lowat','deleted')) as product_cols_4,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='products_public' and column_name in ('wprice','cost')) as leak_cols_must_be_0,
  (select count(*) from pg_policies where schemaname='public' and tablename in ('customers','suppliers','invoices','purchases','payments','movements')) as new_policies_21,
  (select val from public.counters where id='invoice_num') as invoice_counter;
