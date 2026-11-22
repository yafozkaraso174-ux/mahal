-- محل البركة — جولة ٩: المرتجعات + المصروفات + الدرج + قفل اليوم + الخدمات + طريقة الدفع
-- شغّل الملف ده كله مرة واحدة. آمن للتكرار (create if not exists / or replace).

-- ١) طريقة الدفع على الدفعات والفواتير
alter table public.payments add column if not exists method text not null default 'كاش';
alter table public.invoices add column if not exists pay_method text not null default 'كاش';
alter table public.payments drop constraint if exists payments_method_check;
alter table public.payments add constraint payments_method_check check (method in ('كاش','تحويل','رصيد'));
alter table public.invoices drop constraint if exists invoices_pay_method_check;
alter table public.invoices add constraint invoices_pay_method_check check (pay_method in ('كاش','تحويل'));

-- ٢) عداد المرتجعات
insert into public.counters (id, val) values ('return_num', 0) on conflict (id) do nothing;

-- ٣) الجداول الجديدة
create table if not exists public.sales_returns (
  id text primary key default gen_random_uuid()::text,
  num bigint,
  date timestamptz not null default now(),
  invoice_id text,
  invoice_num bigint,
  customer_id text,
  items jsonb not null default '[]'::jsonb,
  total numeric not null default 0,
  refund_method text not null default 'كاش' check (refund_method in ('كاش','تحويل','رصيد')),
  note text not null default '',
  created_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id text primary key default gen_random_uuid()::text,
  date timestamptz not null default now(),
  title text not null default '',
  amount numeric not null default 0,
  method text not null default 'كاش' check (method in ('كاش','تحويل')),
  note text not null default '',
  created_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.drawer_entries (
  id text primary key default gen_random_uuid()::text,
  date timestamptz not null default now(),
  kind text not null check (kind in ('in','out')),
  label text not null default '',
  amount numeric not null default 0,
  note text not null default '',
  created_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.day_closes (
  id text primary key default gen_random_uuid()::text,
  day date not null,
  closed_at timestamptz not null default now(),
  opening numeric not null default 0,
  expected numeric not null default 0,
  actual numeric not null default 0,
  diff numeric not null default 0,
  payload jsonb not null default '{}'::jsonb,
  note text not null default '',
  created_by uuid
);

create table if not exists public.service_txns (
  id text primary key default gen_random_uuid()::text,
  date timestamptz not null default now(),
  kind text not null default 'تحويل' check (kind in ('تحويل','استلام')),
  service text not null default '',
  amount numeric not null default 0,
  fee numeric not null default 0,
  customer_name text not null default '',
  note text not null default '',
  created_by uuid,
  updated_at timestamptz not null default now()
);

drop trigger if exists touch_returns on public.sales_returns;
create trigger touch_returns before update on public.sales_returns for each row execute function public.touch_updated_at();
drop trigger if exists touch_expenses on public.expenses;
create trigger touch_expenses before update on public.expenses for each row execute function public.touch_updated_at();
drop trigger if exists touch_drawer on public.drawer_entries;
create trigger touch_drawer before update on public.drawer_entries for each row execute function public.touch_updated_at();
drop trigger if exists touch_services on public.service_txns;
create trigger touch_services before update on public.service_txns for each row execute function public.touch_updated_at();

-- ٤) الصلاحيات (RLS)
alter table public.sales_returns enable row level security;
alter table public.expenses enable row level security;
alter table public.drawer_entries enable row level security;
alter table public.day_closes enable row level security;
alter table public.service_txns enable row level security;

-- المرتجعات: قراءة بـ "فواتير" أو "إحصائيات"، تسجيل بـ "فواتير"، مسح بـ "مسح بيانات"
create policy "perm read returns" on public.sales_returns for select to authenticated
  using (public.has_shop_perm('invoice') or public.has_shop_perm('stats'));
create policy "perm write returns" on public.sales_returns for insert to authenticated
  with check (public.has_shop_perm('invoice'));
create policy "perm update returns" on public.sales_returns for update to authenticated
  using (public.has_shop_perm('invoice')) with check (public.has_shop_perm('invoice'));
create policy "perm delete returns" on public.sales_returns for delete to authenticated
  using (public.has_shop_perm('del'));

-- المصروفات: كلها بصلاحية "إحصائيات"، مسح بـ "مسح بيانات"
create policy "perm read expenses" on public.expenses for select to authenticated
  using (public.has_shop_perm('stats'));
create policy "perm write expenses" on public.expenses for insert to authenticated
  with check (public.has_shop_perm('stats'));
create policy "perm update expenses" on public.expenses for update to authenticated
  using (public.has_shop_perm('stats')) with check (public.has_shop_perm('stats'));
create policy "perm delete expenses" on public.expenses for delete to authenticated
  using (public.has_shop_perm('del'));

-- الدرج وقفل اليوم: بصلاحية "إحصائيات"، مسح بـ "مسح بيانات"
create policy "perm read drawer" on public.drawer_entries for select to authenticated
  using (public.has_shop_perm('stats'));
create policy "perm write drawer" on public.drawer_entries for insert to authenticated
  with check (public.has_shop_perm('stats'));
create policy "perm update drawer" on public.drawer_entries for update to authenticated
  using (public.has_shop_perm('stats')) with check (public.has_shop_perm('stats'));
create policy "perm delete drawer" on public.drawer_entries for delete to authenticated
  using (public.has_shop_perm('del'));

create policy "perm read day_closes" on public.day_closes for select to authenticated
  using (public.has_shop_perm('stats'));
create policy "perm write day_closes" on public.day_closes for insert to authenticated
  with check (public.has_shop_perm('stats'));
create policy "perm update day_closes" on public.day_closes for update to authenticated
  using (public.has_shop_perm('stats')) with check (public.has_shop_perm('stats'));
create policy "perm delete day_closes" on public.day_closes for delete to authenticated
  using (public.has_shop_perm('del'));

-- الخدمات: قراءة بـ "فواتير" أو "إحصائيات"، تسجيل بـ "فواتير"، مسح بـ "مسح بيانات"
create policy "perm read service_txns" on public.service_txns for select to authenticated
  using (public.has_shop_perm('invoice') or public.has_shop_perm('stats'));
create policy "perm write service_txns" on public.service_txns for insert to authenticated
  with check (public.has_shop_perm('invoice'));
create policy "perm update service_txns" on public.service_txns for update to authenticated
  using (public.has_shop_perm('invoice')) with check (public.has_shop_perm('invoice'));
create policy "perm delete service_txns" on public.service_txns for delete to authenticated
  using (public.has_shop_perm('del'));

-- ٥) تحديث الدوال الموجودة: طريقة الدفع
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
  insert into public.payments (id, date, kind, party_type, party_id, amount, note, method, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), v_kind,
          coalesce(nullif(p->>'partyType',''), case when v_kind='in' then 'c' else 's' end),
          nullif(p->>'partyId',''), coalesce((p->>'amount')::numeric,0), coalesce(p->>'note',''),
          coalesce(nullif(p->>'method',''),'كاش'), auth.uid())
  returning * into v_pay;
  return to_jsonb(v_pay);
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
    if found then return to_jsonb(v_inv); end if;
  end if;
  if v_cust is null or not exists(select 1 from public.customers where id = v_cust and deleted = false) then
    raise exception 'customer missing';
  end if;
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
  insert into public.invoices (id, num, date, customer_id, price_type, items, disc_pct, tax_pct, disc_amt, tax_amt, delivery_fee, total, paid, credit_used, pay_method, created_by)
  values (
    coalesce(v_id, gen_random_uuid()::text), v_num, coalesce((p->>'date')::timestamptz, now()), v_cust,
    coalesce(nullif(p->>'priceType',''),'r'), coalesce(p->'items','[]'::jsonb),
    coalesce((p->>'discPct')::numeric,0), coalesce((p->>'taxPct')::numeric,0),
    coalesce((p->>'discAmt')::numeric,0), coalesce((p->>'taxAmt')::numeric,0),
    coalesce((p->>'deliveryFee')::numeric,0), coalesce((p->>'total')::numeric,0),
    coalesce((p->>'paid')::numeric,0), v_credit,
    coalesce(nullif(p->>'payMethod',''),'كاش'), auth.uid())
  returning * into v_inv;
  update public.movements set ref = 'فاتورة #' || v_num where ref = 'فاتورة' and created_by = auth.uid() and date > now() - interval '1 minute' and pid in (select nullif(it->>'productId','') from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it);
  if v_credit > 0 then
    insert into public.payments (id, date, kind, party_type, party_id, amount, note, method, created_by)
    values (coalesce(nullif(p->>'creditPaymentId',''), gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), 'in', 'c', v_cust, -v_credit, 'خصم من رصيده في فاتورة #' || v_num, 'رصيد', auth.uid())
    on conflict (id) do nothing;
  end if;
  return to_jsonb(v_inv);
end $$;

-- ٦) دوال المزايا الجديدة
create or replace function public.next_return_num() returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.counters (id, val) values ('return_num', 0) on conflict (id) do nothing;
  update public.counters set val = val + 1 where id = 'return_num' returning val into v;
  return v;
end $$;

-- حفظ مرتجع: يرجّع المخزون + يسجّل الحركة + لو الرد "رصيد" بينزل رصيد للعميل
create or replace function public.save_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_item jsonb;
  v_pid text; v_qty numeric; v_before numeric; v_stock numeric;
  v_num bigint;
  v_ret public.sales_returns%rowtype;
  v_refund text := coalesce(nullif(p->>'refundMethod',''),'كاش');
  v_cust text := nullif(p->>'customerId','');
  v_total numeric := coalesce((p->>'total')::numeric,0);
begin
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_ret from public.sales_returns where id = v_id;
    if found then return to_jsonb(v_ret); end if;  -- اتسجل قبل كده (إعادة محاولة)
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_pid is not null then
      select stock into v_before from public.products where id = v_pid for update;
      if found then
        update public.products set stock = round((stock + v_qty)::numeric, 2) where id = v_pid returning stock into v_stock;
        insert into public.movements (id, pid, kind, qty, qty_before, qty_after, ref, date, created_by)
        values (coalesce(nullif(v_item->>'moveId',''), gen_random_uuid()::text), v_pid, 'return', v_qty, v_before, v_stock, 'مرتجع', coalesce((p->>'date')::timestamptz, now()), auth.uid());
      end if;
    end if;
  end loop;
  v_num := public.next_return_num();
  insert into public.sales_returns (id, num, date, invoice_id, invoice_num, customer_id, items, total, refund_method, note, created_by)
  values (
    coalesce(v_id, gen_random_uuid()::text), v_num, coalesce((p->>'date')::timestamptz, now()),
    nullif(p->>'invoiceId',''), (nullif(p->>'invoiceNum',''))::bigint, v_cust,
    coalesce(p->'items','[]'::jsonb), v_total, v_refund, coalesce(p->>'note',''), auth.uid())
  returning * into v_ret;
  update public.movements set ref = 'مرتجع #' || v_num where ref = 'مرتجع' and created_by = auth.uid() and date > now() - interval '1 minute' and pid in (select nullif(it->>'productId','') from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it);
  if v_refund = 'رصيد' and v_cust is not null and v_total > 0 then
    insert into public.payments (id, date, kind, party_type, party_id, amount, note, method, created_by)
    values (coalesce(nullif(p->>'creditPaymentId',''), gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), 'in', 'c', v_cust, -v_total, 'رصيد مرتجع #' || v_num, 'رصيد', auth.uid())
    on conflict (id) do nothing;
  end if;
  return to_jsonb(v_ret);
end $$;

-- حفظ مصروف
create or replace function public.save_expense(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_row public.expenses%rowtype;
begin
  if not public.has_shop_perm('stats') then raise exception 'no permission: stats'; end if;
  if v_id is not null then
    select * into v_row from public.expenses where id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.expenses (id, date, title, amount, method, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(p->>'title',''), coalesce((p->>'amount')::numeric,0),
          coalesce(nullif(p->>'method',''),'كاش'), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- حركة درج يدوية (افتتاح / سحب / إيداع)
create or replace function public.save_drawer_entry(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_row public.drawer_entries%rowtype;
begin
  if not public.has_shop_perm('stats') then raise exception 'no permission: stats'; end if;
  if v_id is not null then
    select * into v_row from public.drawer_entries where id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.drawer_entries (id, date, kind, label, amount, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(nullif(p->>'kind',''),'in'), coalesce(p->>'label',''),
          coalesce((p->>'amount')::numeric,0), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- قفل اليوم: لقطة مجمّعة (المتوقع × الفعلي × الفرق)
create or replace function public.close_day(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_row public.day_closes%rowtype;
begin
  if not public.has_shop_perm('stats') then raise exception 'no permission: stats'; end if;
  if v_id is not null then
    select * into v_row from public.day_closes where id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.day_closes (id, day, opening, expected, actual, diff, payload, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text),
          coalesce((p->>'day')::date, current_date),
          coalesce((p->>'opening')::numeric,0), coalesce((p->>'expected')::numeric,0),
          coalesce((p->>'actual')::numeric,0), coalesce((p->>'diff')::numeric,0),
          coalesce(p->'payload','{}'::jsonb), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- حفظ عملية خدمة (فودافون كاش وغيرها): المبلغ + العمولة
create or replace function public.save_service_txn(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_row public.service_txns%rowtype;
begin
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_row from public.service_txns where id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.service_txns (id, date, kind, service, amount, fee, customer_name, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(nullif(p->>'kind',''),'تحويل'), coalesce(p->>'service',''),
          coalesce((p->>'amount')::numeric,0), coalesce((p->>'fee')::numeric,0),
          coalesce(p->>'customerName',''), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

-- ٧) صلاحيات التنفيذ
revoke all on function public.next_return_num() from public;
revoke all on function public.save_return(jsonb) from public;
grant execute on function public.save_return(jsonb) to authenticated;
revoke all on function public.save_expense(jsonb) from public;
grant execute on function public.save_expense(jsonb) to authenticated;
revoke all on function public.save_drawer_entry(jsonb) from public;
grant execute on function public.save_drawer_entry(jsonb) to authenticated;
revoke all on function public.close_day(jsonb) from public;
grant execute on function public.close_day(jsonb) to authenticated;
revoke all on function public.save_service_txn(jsonb) from public;
grant execute on function public.save_service_txn(jsonb) to authenticated;

-- ٨) فحص ذاتي
do $$
begin
  if (select count(*) from information_schema.tables where table_schema='public'
      and table_name in ('sales_returns','expenses','drawer_entries','day_closes','service_txns')) < 5 then
    raise exception 'ROUND9 FAIL: ناقص جداول'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='payments' and column_name='method') then
    raise exception 'ROUND9 FAIL: payments.method ناقص'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='invoices' and column_name='pay_method') then
    raise exception 'ROUND9 FAIL: invoices.pay_method ناقص'; end if;
  if (select count(*) from information_schema.routines where routine_schema='public'
      and routine_name in ('next_return_num','save_return','save_expense','save_drawer_entry','close_day','save_service_txn')) < 6 then
    raise exception 'ROUND9 FAIL: ناقص دوال'; end if;
  if (select count(*) from pg_policies where schemaname='public'
      and tablename in ('sales_returns','expenses','drawer_entries','day_closes','service_txns')) < 19 then
    raise exception 'ROUND9 FAIL: سياسات ناقصة'; end if;
  if (select count(*) from pg_tables where schemaname='public'
      and tablename in ('sales_returns','expenses','drawer_entries','day_closes','service_txns') and rowsecurity) < 5 then
    raise exception 'ROUND9 FAIL: RLS مش مفعّل'; end if;
  raise notice 'ROUND9 PASS';
end $$;

select
  (select count(*) from information_schema.tables where table_schema='public' and table_name in ('sales_returns','expenses','drawer_entries','day_closes','service_txns')) as tables_5,
  (select count(*) from information_schema.routines where routine_schema='public' and routine_name in ('next_return_num','save_return','save_expense','save_drawer_entry','close_day','save_service_txn')) as functions_6,
  (select count(*) from pg_policies where schemaname='public' and tablename in ('sales_returns','expenses','drawer_entries','day_closes','service_txns')) as policies_19,
  (select column_name from information_schema.columns where table_schema='public' and table_name='payments' and column_name='method') as payments_method,
  (select column_name from information_schema.columns where table_schema='public' and table_name='invoices' and column_name='pay_method') as invoices_pay_method;
