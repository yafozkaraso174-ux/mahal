-- Legacy mobile installment queues: upgrade the payment into the atomic action,
-- then accept stale matching contract snapshots without rolling allocations back.
begin;
do $$begin
 if to_regprocedure('public.record_payment_legacy(jsonb)') is null then
  alter function public.record_payment(jsonb) rename to record_payment_legacy;
 end if;
end $$;
revoke all on function record_payment_legacy(jsonb) from public,anon,authenticated;
create or replace function record_payment(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare tid uuid:=my_tenant();ct installment_contracts%rowtype;q jsonb;r jsonb;cnt int;prior mobile_receipt_ops%rowtype;
begin
 if exists(select 1 from tenants where id=tid and shop_type='mobile') and p->>'kind'='in' and p->>'partyType'='c' and coalesce(p->>'note','') like 'قسط عقد تقسيط #%'
 then
  if not tenant_active() or not(has_shop_perm('invoice') or has_shop_perm('customers')) then raise exception 'no permission';end if;
  perform pg_advisory_xact_lock(hashtextextended(tid::text||(p->>'id'),0));
  select * into prior from mobile_receipt_ops where tenant_id=tid and id=p->>'id';
  if found then
   if prior.request->>'customerId' is distinct from p->>'partyId' or (prior.request->>'amount')::numeric is distinct from (p->>'amount')::numeric or prior.request->>'note' is distinct from p->>'note' or prior.request->>'method' is distinct from p->>'method' then raise exception 'legacy receipt conflict';end if;
   r:=mobile_receive_payment(prior.request);return r->'payment';
  end if;
  -- Preserve old successful payment retries from before this migration.
  if exists(select 1 from payments where tenant_id=tid and id=p->>'id') then return record_payment_legacy(p);end if;
  perform 1 from customers where id=p->>'partyId' and tenant_id=tid for update;
  select count(*) into cnt from installment_contracts where tenant_id=tid and not deleted and data->>'customerId'=p->>'partyId' and data->>'invoiceNum'=substring(p->>'note' from length('قسط عقد تقسيط #')+1);
  if cnt<>1 then raise exception 'legacy contract needs review';end if;
  select * into ct from installment_contracts where tenant_id=tid and not deleted and data->>'customerId'=p->>'partyId' and data->>'invoiceNum'=substring(p->>'note' from length('قسط عقد تقسيط #')+1) for update;
  q:=jsonb_build_object('id',p->>'id','customerId',p->>'partyId','amount',(p->>'amount')::numeric,'method',coalesce(nullif(p->>'method',''),'كاش'),'note',p->>'note','contractId',ct.id,'expectedSchedule',ct.data->'schedule');
  r:=mobile_receive_payment(q);return r->'payment';
 end if;
 return record_payment_legacy(p);
end $$;
revoke all on function record_payment(jsonb) from public,anon;
grant execute on function record_payment(jsonb) to authenticated;
create or replace function guard_mobile_receipt_schedule() returns trigger language plpgsql security definer set search_path=public as $$
declare x jsonb;y jsonb;oldsch jsonb;newsch jsonb;i int;current_paid numeric;proposed_paid numeric;funded numeric;delta numeric;need numeric;take numeric;merged jsonb;
begin
 if TG_OP='DELETE' then if exists(select 1 from payments where tenant_id=old.tenant_id and contract_id=old.id) then raise exception 'contract has receipts';end if;return old;end if;
 if coalesce(current_setting('mahal.atomic_receipt',true),'')<>'yes' and exists(select 1 from payments where tenant_id=old.tenant_id and contract_id=old.id) then
  if new.deleted is distinct from old.deleted or new.data->>'customerId' is distinct from old.data->>'customerId' or new.data->>'invoiceId' is distinct from old.data->>'invoiceId' or new.data->>'total' is distinct from old.data->>'total' then raise exception 'contract has atomic receipts; refresh and use receipt action';end if;
  oldsch:=old.data->'schedule';newsch:=new.data->'schedule';
  if jsonb_array_length(oldsch) is distinct from jsonb_array_length(newsch) then raise exception 'legacy schedule changed';end if;
  for i in 0..jsonb_array_length(oldsch)-1 loop
   x:=oldsch->i;y:=newsch->i;
   if (x-'paidAmt'-'paidAt') is distinct from (y-'paidAmt'-'paidAt')  then raise exception 'legacy schedule needs review';end if;
  end loop;
  select coalesce(sum(coalesce((v->>'paidAmt')::numeric,0)),0) into current_paid from jsonb_array_elements(oldsch)v;
  select coalesce(sum(coalesce((v->>'paidAmt')::numeric,0)),0) into proposed_paid from jsonb_array_elements(newsch)v;
  if proposed_paid>current_paid then
   -- Handles a receipt that saved before upgrade while its offline schedule update is still queued.
   select coalesce(sum(amount),0) into funded from payments where tenant_id=old.tenant_id and kind='in' and party_type='c' and party_id=old.data->>'customerId' and (contract_id=old.id or (contract_id is null and note='قسط عقد تقسيط #'||(old.data->>'invoiceNum')));
   if proposed_paid>funded then raise exception 'legacy schedule not funded by receipts';end if;
   delta:=proposed_paid-current_paid;merged:='[]'::jsonb;
   for x in select value from jsonb_array_elements(oldsch) loop
    need:=greatest(0,(x->>'amt')::numeric-coalesce((x->>'paidAmt')::numeric,0));take:=least(need,delta);delta:=delta-take;
    if take>0 then x:=x||jsonb_build_object('paidAmt',coalesce((x->>'paidAmt')::numeric,0)+take);if take=need then x:=x||jsonb_build_object('paidAt',now());end if;end if;
    merged:=merged||jsonb_build_array(x);
   end loop;oldsch:=merged;
  end if;
  -- A matching old snapshot is acknowledged but cannot undo any receipts.
  new.data:=jsonb_set(new.data,'{schedule}',oldsch);
 end if;return new;
end $$;
notify pgrst,'reload schema';
commit;
