BEGIN;
CREATE OR REPLACE FUNCTION public.close_day(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(p->>'id','');
  v_row public.day_closes%rowtype;
begin

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('stats') then raise exception 'no permission: stats'; end if;
  if v_id is not null then
    select * into v_row from public.day_closes where tenant_id = public.my_tenant() and id = v_id;
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
end $function$
;
CREATE OR REPLACE FUNCTION public.next_invoice_num()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v bigint; t uuid := public.my_tenant();
begin
 if not public.tenant_active() then raise exception 'tenant inactive'; end if;
  insert into public.counters (tenant_id, id, val) values (t, 'invoice_num', 1000) on conflict (tenant_id, id) do nothing;
  update public.counters set val = val + 1 where tenant_id = t and id = 'invoice_num' returning val into v;
  return v;
end $function$
;
CREATE OR REPLACE FUNCTION public.next_return_num()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v bigint; t uuid := public.my_tenant();
begin
 if not public.tenant_active() then raise exception 'tenant inactive'; end if;
  insert into public.counters (tenant_id, id, val) values (t, 'return_num', 0) on conflict (tenant_id, id) do nothing;
  update public.counters set val = val + 1 where tenant_id = t and id = 'return_num' returning val into v;
  return v;
end $function$
;
CREATE OR REPLACE FUNCTION public.record_payment(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(p->>'id','');
  v_kind text := coalesce(nullif(p->>'kind',''),'in');
  v_pay public.payments%rowtype;
begin

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if nullif(p->>'partyId','') is not null and not (
   exists(select 1 from public.customers c where c.id=p->>'partyId' and c.tenant_id=public.my_tenant()) or
   exists(select 1 from public.suppliers s where s.id=p->>'partyId' and s.tenant_id=public.my_tenant()))
   then raise exception 'party missing'; end if;
  if v_kind = 'in' then
    if not (public.has_shop_perm('invoice') or public.has_shop_perm('customers')) then raise exception 'no permission'; end if;
  else
    if not public.has_shop_perm('suppliers') then raise exception 'no permission'; end if;
  end if;
  if v_id is not null then
    select * into v_pay from public.payments where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_pay); end if;
  end if;
  insert into public.payments (id, date, kind, party_type, party_id, amount, note, method, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), v_kind,
          coalesce(nullif(p->>'partyType',''), case when v_kind='in' then 'c' else 's' end),
          nullif(p->>'partyId',''), coalesce((p->>'amount')::numeric,0), coalesce(p->>'note',''),
          coalesce(nullif(p->>'method',''),'كاش'), auth.uid())
  returning * into v_pay;
  return to_jsonb(v_pay);
end $function$
;
CREATE OR REPLACE FUNCTION public.save_drawer_entry(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(p->>'id','');
  v_row public.drawer_entries%rowtype;
begin

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('stats') then raise exception 'no permission: stats'; end if;
  if v_id is not null then
    select * into v_row from public.drawer_entries where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.drawer_entries (id, date, kind, label, amount, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(nullif(p->>'kind',''),'in'), coalesce(p->>'label',''),
          coalesce((p->>'amount')::numeric,0), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $function$
;
CREATE OR REPLACE FUNCTION public.save_expense(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(p->>'id','');
  v_row public.expenses%rowtype;
begin

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('stats') then raise exception 'no permission: stats'; end if;
  if v_id is not null then
    select * into v_row from public.expenses where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.expenses (id, date, title, amount, method, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(p->>'title',''), coalesce((p->>'amount')::numeric,0),
          coalesce(nullif(p->>'method',''),'كاش'), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $function$
;
CREATE OR REPLACE FUNCTION public.save_invoice(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_inv from public.invoices where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_inv); end if;
  end if;
  if v_cust is null or not exists(select 1 from public.customers where tenant_id = public.my_tenant() and id = v_cust and deleted = false) then
    raise exception 'customer missing';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_pid is not null then
      select stock, name into v_stock, v_name from public.products where tenant_id = public.my_tenant() and id = v_pid for update;
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
      select stock into v_before from public.products where tenant_id = public.my_tenant() and id = v_pid;
      if found then
        update public.products set stock = round((stock - v_qty)::numeric, 2) where tenant_id = public.my_tenant() and id = v_pid returning stock into v_stock;
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
  update public.movements set ref = 'فاتورة #' || v_num where tenant_id = public.my_tenant() and ref = 'فاتورة' and created_by = auth.uid() and date > now() - interval '1 minute' and pid in (select nullif(it->>'productId','') from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it);
  if v_credit > 0 then
    insert into public.payments (id, date, kind, party_type, party_id, amount, note, method, created_by)
    values (coalesce(nullif(p->>'creditPaymentId',''), gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), 'in', 'c', v_cust, -v_credit, 'خصم من رصيده في فاتورة #' || v_num, 'رصيد', auth.uid())
    on conflict (id) do nothing;
  end if;
  return to_jsonb(v_inv);
end $function$
;
CREATE OR REPLACE FUNCTION public.save_purchase(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(p->>'id','');
  v_supp text := nullif(p->>'supplierId','');
  v_item jsonb;
  v_pid text; v_qty numeric; v_cost numeric; v_stock numeric; v_before numeric;
  v_pur public.purchases%rowtype;
begin

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('suppliers') then raise exception 'no permission: suppliers'; end if;
  if v_id is not null then
    select * into v_pur from public.purchases where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_pur); end if;
  end if;
  if v_supp is null or not exists(select 1 from public.suppliers where tenant_id = public.my_tenant() and id = v_supp and deleted = false) then
    raise exception 'supplier missing';
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    v_cost := coalesce((v_item->>'cost')::numeric, 0);
    if v_pid is not null then
      select stock into v_before from public.products where tenant_id = public.my_tenant() and id = v_pid for update;
      if found then
        update public.products set stock = round((stock + v_qty)::numeric, 2), cost = v_cost where tenant_id = public.my_tenant() and id = v_pid returning stock into v_stock;
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
end $function$
;
CREATE OR REPLACE FUNCTION public.save_return(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_ret from public.sales_returns where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_ret); end if;  -- اتسجل قبل كده (إعادة محاولة)
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_pid is not null then
      select stock into v_before from public.products where tenant_id = public.my_tenant() and id = v_pid for update;
      if found then
        update public.products set stock = round((stock + v_qty)::numeric, 2) where tenant_id = public.my_tenant() and id = v_pid returning stock into v_stock;
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
  update public.movements set ref = 'مرتجع #' || v_num where tenant_id = public.my_tenant() and ref = 'مرتجع' and created_by = auth.uid() and date > now() - interval '1 minute' and pid in (select nullif(it->>'productId','') from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) it);
  if v_refund = 'رصيد' and v_cust is not null and v_total > 0 then
    insert into public.payments (id, date, kind, party_type, party_id, amount, note, method, created_by)
    values (coalesce(nullif(p->>'creditPaymentId',''), gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()), 'in', 'c', v_cust, -v_total, 'رصيد مرتجع #' || v_num, 'رصيد', auth.uid())
    on conflict (id) do nothing;
  end if;
  return to_jsonb(v_ret);
end $function$
;
CREATE OR REPLACE FUNCTION public.save_service_txn(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id text := nullif(p->>'id','');
  v_row public.service_txns%rowtype;
begin

  if public.my_tenant() is null or not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) x
    where nullif(x->>'productId','') is not null and not exists
     (select 1 from public.products pr where pr.id=x->>'productId' and pr.tenant_id=public.my_tenant()))
    then raise exception 'missing product'; end if;
  if nullif(p->>'customerId','') is not null and not exists
   (select 1 from public.customers c where c.id=p->>'customerId' and c.tenant_id=public.my_tenant())
   then raise exception 'customer missing'; end if;
  if nullif(p->>'supplierId','') is not null and not exists
   (select 1 from public.suppliers s where s.id=p->>'supplierId' and s.tenant_id=public.my_tenant())
   then raise exception 'supplier missing'; end if;
  if nullif(p->>'invoiceId','') is not null and not exists
   (select 1 from public.invoices i where i.id=p->>'invoiceId' and i.tenant_id=public.my_tenant())
   then raise exception 'invoice missing'; end if;
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_row from public.service_txns where tenant_id = public.my_tenant() and id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.service_txns (id, date, kind, service, network, amount, fee, customer_name, customer_phone, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(nullif(p->>'kind',''),'تحويل'), coalesce(p->>'service',''),
          coalesce(p->>'network',''),
          coalesce((p->>'amount')::numeric,0), coalesce((p->>'fee')::numeric,0),
          coalesce(p->>'customerName',''), coalesce(p->>'customerPhone',''), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $function$
;
CREATE OR REPLACE FUNCTION public.set_invoice_counter(v bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if not public.tenant_active() then raise exception 'tenant inactive'; end if;
  if not public.is_shop_owner() then raise exception 'no permission'; end if;
  insert into public.counters (tenant_id, id, val) values (public.my_tenant(), 'invoice_num', v)
  on conflict (tenant_id, id) do update set val = greatest(public.counters.val, excluded.val);
end $function$
;

alter table public.backups drop constraint if exists backups_pkey;
alter table public.backups add primary key(tenant_id,id);
alter table public.shop_users alter column tenant_id set default public.my_tenant();
create unique index if not exists shop_users_auth_unique on public.shop_users(auth_id) where auth_id is not null;
drop policy if exists "bootstrap first owner" on public.shop_users;
-- Only tenant 1 currently has an approved public storefront.
create or replace view public.products_public as
 select tenant_id,id,name,cat,unit,price,stock,photo_url from public.products
 where not deleted and tenant_id=public.store_tenant();
drop policy if exists "perm write product photos" on storage.objects;
create policy "tenant write product photos" on storage.objects for all to authenticated
 using (bucket_id='product-photos' and public.tenant_active() and public.has_shop_perm('products') and exists
  (select 1 from public.products p where p.tenant_id=public.my_tenant() and storage.objects.name=p.id||'.jpg'))
 with check (bucket_id='product-photos' and public.tenant_active() and public.has_shop_perm('products') and exists
  (select 1 from public.products p where p.tenant_id=public.my_tenant() and storage.objects.name=p.id||'.jpg'));
NOTIFY pgrst, 'reload schema';
COMMIT;
