create table if not exists suppliers(id text,tenant_id uuid);create table if not exists products(id text,tenant_id uuid);
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
