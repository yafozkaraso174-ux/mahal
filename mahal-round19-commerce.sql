-- LOCAL PROPOSAL ONLY. Not executed on Supabase.
-- Apply before deploying the commerce build. Existing oils invoice behavior stays unchanged.
begin;
alter table public.products add column if not exists unit_config jsonb;
create table if not exists public.offers(
 id text primary key,
 tenant_id uuid not null default public.my_tenant() references public.tenants(id),
 data jsonb not null default '{}'::jsonb,
 deleted boolean not null default false,
 updated_at timestamptz not null default now());
create index if not exists offers_tenant_updated on public.offers(tenant_id,updated_at);
alter table public.offers enable row level security;
drop policy if exists "tenant offers read" on public.offers;
create policy "tenant offers read" on public.offers for select to authenticated
 using(tenant_id=public.my_tenant() and public.tenant_active());
drop policy if exists "owner offers insert" on public.offers;
create policy "owner offers insert" on public.offers for insert to authenticated
 with check(tenant_id=public.my_tenant() and public.tenant_active() and exists(select 1 from public.shop_users s where s.auth_id=auth.uid() and s.tenant_id=public.my_tenant() and s.owner and s.active));
drop policy if exists "owner offers update" on public.offers;
create policy "owner offers update" on public.offers for update to authenticated
 using(tenant_id=public.my_tenant() and public.tenant_active() and exists(select 1 from public.shop_users s where s.auth_id=auth.uid() and s.tenant_id=public.my_tenant() and s.owner and s.active))
 with check(tenant_id=public.my_tenant() and public.tenant_active() and exists(select 1 from public.shop_users s where s.auth_id=auth.uid() and s.tenant_id=public.my_tenant() and s.owner and s.active));
revoke all on public.offers from anon;
grant select,insert,update on public.offers to authenticated;
-- Owner writes are serialized per tenant to reject overlapping offers even on two devices.
create or replace function public.check_offer() returns trigger language plpgsql set search_path=public as $$
declare pid text; other record; st timestamptz; en timestamptz;
begin
 perform pg_advisory_xact_lock(hashtextextended(new.tenant_id::text,0));
 if new.deleted then return new; end if;
 if jsonb_typeof(new.data) is distinct from 'object' or nullif(btrim(new.data->>'name'),'') is null or jsonb_typeof(new.data->'productIds') is distinct from 'array' then raise exception 'missing: offer name/products'; end if;
 if jsonb_array_length(new.data->'productIds')=0 then raise exception 'missing: offer products';end if;
 if not coalesce(new.data->>'kind' in ('pct','fixed'),false) or jsonb_typeof(new.data->'value') is distinct from 'number' or coalesce((new.data->>'value')::numeric,0)<=0 or (new.data->>'value')::numeric>1000000000000 or (new.data->>'kind'='pct' and (new.data->>'value')::numeric>100) then raise exception 'missing: invalid offer value'; end if;
 st:=coalesce(nullif(new.data->>'startsAt','')::timestamptz,'-infinity');en:=coalesce(nullif(new.data->>'endsAt','')::timestamptz,'infinity');
 if st>=en then raise exception 'missing: invalid offer dates'; end if;
 for pid in select jsonb_array_elements_text(new.data->'productIds') loop
  if not exists(select 1 from products p where p.id=pid and p.tenant_id=new.tenant_id and not p.deleted) then raise exception 'missing product'; end if;
  if coalesce((new.data->>'active')::boolean,false) then
   for other in select o.* from offers o where o.tenant_id=new.tenant_id and o.id<>new.id and not o.deleted and coalesce((o.data->>'active')::boolean,false) and (o.data->'productIds') ? pid loop
    if st<=coalesce(nullif(other.data->>'endsAt','')::timestamptz,'infinity') and en>=coalesce(nullif(other.data->>'startsAt','')::timestamptz,'-infinity') then raise exception 'missing: overlapping offer'; end if;
   end loop;
  end if;
 end loop;
 return new;
end $$;
drop trigger if exists offers_validate on public.offers;
create trigger offers_validate before insert or update on public.offers for each row execute function public.check_offer();
create or replace view public.offers_public as
 select o.id,o.tenant_id,jsonb_build_object('name',o.data->>'name','productIds',o.data->'productIds','kind',o.data->>'kind','value',o.data->'value','startsAt',o.data->'startsAt','endsAt',o.data->'endsAt','active',o.data->'active') as data
 from public.offers o join public.tenants t on t.id=o.tenant_id
 where not o.deleted and coalesce((o.data->>'active')::boolean,false) and now()>=coalesce(nullif(o.data->>'startsAt','')::timestamptz,'-infinity') and now()<=coalesce(nullif(o.data->>'endsAt','')::timestamptz,'infinity') and o.tenant_id=public.store_tenant() and t.status='active' and (t.sub_end is null or t.sub_end>=current_date);
grant select on public.offers_public to anon,authenticated;
create or replace view public.products_public as
 select tenant_id,id,name,cat,unit,price,stock,photo_url,case when unit_config is null then null else jsonb_strip_nulls(jsonb_build_object('base',unit_config->'base','packLabel',unit_config->'packLabel','packFactor',unit_config->'packFactor','area',unit_config->'area','discrete',unit_config->'discrete','wholePack',unit_config->'wholePack')) end as unit_config from public.products
 where not deleted and tenant_id=public.store_tenant();
grant select on public.products_public to anon,authenticated;
-- Only new commerce store orders are checked here. Old, unconfigured orders are unchanged.
create or replace function public.validate_commerce_order() returns trigger
 language plpgsql security definer set search_path=public as $$
declare it jsonb; p public.products%rowtype; o record; off jsonb; q numeric; expected numeric; total_items numeric:=0; rebuilt jsonb:='[]'; advanced boolean:=false; n integer;
begin
 if new.tenant_id<>public.store_tenant() then raise exception 'missing: store tenant'; end if;
 if exists(select 1 from jsonb_array_elements(new.items) x where coalesce((x->>'qty')::numeric,0)<=0) then raise exception 'missing: positive order quantity';end if;
 if exists(select 1 from jsonb_array_elements(new.items) x where not exists(select 1 from products pp where pp.id=x->>'id' and pp.tenant_id=new.tenant_id and not pp.deleted)) then raise exception 'missing product';end if;
 if not exists(select 1 from jsonb_array_elements(new.items) x join products pr on pr.id=x->>'id' and pr.tenant_id=new.tenant_id where x ? 'commerce' or pr.unit_config is not null or exists(select 1 from offers f where f.tenant_id=new.tenant_id and not f.deleted and coalesce((f.data->>'active')::boolean,false) and (f.data->'productIds') ? pr.id and now()>=coalesce(nullif(f.data->>'startsAt','')::timestamptz,'-infinity') and now()<=coalesce(nullif(f.data->>'endsAt','')::timestamptz,'infinity'))) then return new;end if;
 for it in select * from jsonb_array_elements(new.items) loop
  select * into p from products where id=it->>'id' and tenant_id=new.tenant_id and not deleted;
  if not found then raise exception 'missing product'; end if;
  q:=coalesce((it->>'qty')::numeric,0);if q<=0 or q>p.stock then raise exception 'shortage: store quantity';end if;
  off:=null;n:=0;expected:=p.price;
  for o in select * from offers where tenant_id=new.tenant_id and not deleted and coalesce((data->>'active')::boolean,false) and (data->'productIds') ? p.id and now()>=coalesce(nullif(data->>'startsAt','')::timestamptz,'-infinity') and now()<=coalesce(nullif(data->>'endsAt','')::timestamptz,'infinity') order by id loop
   n:=n+1;
   expected:=round(greatest(0,case when o.data->>'kind'='pct' then p.price*(1-(o.data->>'value')::numeric/100) else p.price-(o.data->>'value')::numeric end),6);
   off:=jsonb_build_object('id',o.id,'name',o.data->>'name','kind',o.data->>'kind','value',o.data->'value','original',p.price,'price',expected,'quotedAt',now());
  end loop;
  if n>1 then raise exception 'missing: overlapping offers';end if;
  if p.unit_config is not null or off is not null or it ? 'commerce' then
   advanced:=true;
   if abs(coalesce((it->>'price')::numeric,-1)-expected)>0.000001 then raise exception 'missing: price changed, reload store';end if;
   if p.unit_config is not null and coalesce((p.unit_config->>'discrete')::boolean,false) and q<>trunc(q) then raise exception 'missing: whole pieces required';end if;
   if q<>round(q,3) then raise exception 'missing: quantity precision';end if;
   it:=it||jsonb_build_object('name',p.name,'unit',p.unit,'price',expected,'commerce',jsonb_strip_nulls(jsonb_build_object('offer',off,'unitConfig',p.unit_config,'saleQty',q,'saleUnit',p.unit,'factor',1)));
  end if;
  total_items:=total_items+q*(it->>'price')::numeric;rebuilt:=rebuilt||jsonb_build_array(it);
 end loop;
 if advanced then
  if abs(new.total-round(total_items+coalesce(new.delivery_fee,0),2))>0.001 then raise exception 'missing: store total';end if;
  new.items:=rebuilt;
 end if;
 return new;
end $$;
drop trigger if exists commerce_store_order on public.orders;
create trigger commerce_store_order before insert on public.orders for each row execute function public.validate_commerce_order();
-- A configured base unit cannot be relabeled while stock/history would be reinterpreted.
create or replace function public.validate_product_units() returns trigger
 language plpgsql security definer set search_path=public as $$
declare c jsonb:=new.unit_config;
begin
 if tg_op='UPDATE' and (old.unit_config is not null or c is not null) and
  (new.unit is distinct from old.unit or (c is null and old.unit_config is not null)) and
  (old.stock<>0 or exists(select 1 from invoices i cross join lateral jsonb_array_elements(i.items) it where i.tenant_id=old.tenant_id and it->>'productId'=old.id))
  then raise exception 'missing: base unit has stock/history';end if;
 if c is null then return new;end if;
 if jsonb_typeof(c) is distinct from 'object' or nullif(c->>'base','') is null or c->>'base' is distinct from new.unit then raise exception 'missing: invalid base unit';end if;
 if coalesce((c->>'packFactor')::numeric,0)<0 or coalesce((c->>'area')::numeric,0)<0 then raise exception 'missing: negative unit conversion';end if;
 if nullif(c->>'packLabel','') is not null and coalesce((c->>'packFactor')::numeric,0)<=0 then raise exception 'missing: pack conversion';end if;
 if coalesce((c->>'area')::numeric,0)>0 and c->>'base'<>'قطعة' then raise exception 'missing: area needs pieces';end if;
 if coalesce((c->>'discrete')::boolean,false) and coalesce((c->>'packFactor')::numeric,0)<>trunc(coalesce((c->>'packFactor')::numeric,0)) then raise exception 'missing: fractional pieces per pack';end if;
 return new;
end $$;
drop trigger if exists product_units_validate on public.products;
create trigger product_units_validate before insert or update on public.products for each row execute function public.validate_product_units();

-- RPC precision changes below are gated on saved commerce item metadata.

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
    if v_item ? 'commerce' and (v_qty<=0 or v_qty<>round(v_qty,3)) then raise exception 'missing: invalid commerce quantity';end if;
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
    if v_item ? 'commerce' and (v_qty<=0 or v_qty<>round(v_qty,3)) then raise exception 'missing: invalid commerce quantity';end if;
    if v_pid is not null then
      select stock into v_before from public.products where tenant_id = public.my_tenant() and id = v_pid;
      if found then
        update public.products set stock = round((stock - v_qty)::numeric, case when v_item ? 'commerce' or exists(select 1 from products pr where pr.id=v_pid and pr.tenant_id=my_tenant() and pr.unit_config is not null) then 3 else 2 end) where tenant_id = public.my_tenant() and id = v_pid returning stock into v_stock;
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
  if not exists(select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) z where z ? 'commerce') and exists(select 1 from invoices i cross join lateral jsonb_array_elements(i.items) z where i.id=p->>'invoiceId' and i.tenant_id=my_tenant() and z ? 'commerce') then raise exception 'missing: update app for this invoice return';end if;
  -- Serialize new-format returns per source invoice, then cap each saved source line.
  if exists(select 1 from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) z where z ? 'commerce') then
   perform 1 from invoices i where i.id=p->>'invoiceId' and i.tenant_id=my_tenant() for update;
   if exists(
    select 1 from jsonb_array_elements(p->'items') z
    where z ? 'commerce' and (
     nullif(z->>'sourceMoveId','') is null or not exists(
      select 1 from invoices i cross join lateral jsonb_array_elements(i.items) src
      where i.id=p->>'invoiceId' and i.tenant_id=my_tenant() and src->>'moveId'=z->>'sourceMoveId' and src->>'productId'=z->>'productId'
      and abs((z->>'price')::numeric - (src->>'price')::numeric * (1-case when coalesce(i.disc_amt,0)>0 then i.disc_amt/nullif((select sum((ii->>'qty')::numeric*(ii->>'price')::numeric) from jsonb_array_elements(i.items) ii),0) else 0 end))<0.000001
      and (select sum((req->>'qty')::numeric) from jsonb_array_elements(p->'items') req where req->>'sourceMoveId'=z->>'sourceMoveId') <=
       (src->>'qty')::numeric-coalesce((select sum((ri->>'qty')::numeric) from sales_returns sr cross join lateral jsonb_array_elements(sr.items) ri where sr.tenant_id=my_tenant() and sr.invoice_id=i.id and ri->>'sourceMoveId'=src->>'moveId'),0)
     ))) then raise exception 'missing: invalid return source/quantity/price';end if;
  end if;
  for v_item in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    v_pid := nullif(v_item->>'productId','');
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_item ? 'commerce' and (v_qty<=0 or v_qty<>round(v_qty,3)) then raise exception 'missing: invalid commerce quantity';end if;
    if v_pid is not null then
      select stock into v_before from public.products where tenant_id = public.my_tenant() and id = v_pid for update;
      if found then
        update public.products set stock = round((stock + v_qty)::numeric, case when v_item ? 'commerce' or exists(select 1 from products pr where pr.id=v_pid and pr.tenant_id=my_tenant() and pr.unit_config is not null) then 3 else 2 end) where tenant_id = public.my_tenant() and id = v_pid returning stock into v_stock;
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
        update public.products set stock = round((stock + v_qty)::numeric, case when exists(select 1 from products pr where pr.id=v_pid and pr.tenant_id=my_tenant() and pr.unit_config is not null) then 3 else 2 end), cost = v_cost where tenant_id = public.my_tenant() and id = v_pid returning stock into v_stock;
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
NOTIFY pgrst,'reload schema';
commit;
