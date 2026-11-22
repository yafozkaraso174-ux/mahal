-- LOCAL ONLY: atomic mobile customer receipt and optional installment allocation.
begin;
alter table public.payments add column if not exists contract_id text;
create table if not exists public.mobile_receipt_ops(tenant_id uuid not null references tenants(id),id text not null,actor uuid not null,request jsonb not null,result jsonb not null,primary key(tenant_id,id));
alter table public.mobile_receipt_ops enable row level security;
revoke all on public.mobile_receipt_ops from public,anon,authenticated;
create or replace function public.mobile_receive_payment(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare tid uuid:=my_tenant();cid text:=p->>'customerId';pid text:=p->>'id';ct text:=nullif(p->>'contractId','');a numeric:=(p->>'amount')::numeric;bal numeric;leftamt numeric;remaining numeric;need numeric;take numeric;sc jsonb:='[]';x jsonb;c installment_contracts%rowtype;old mobile_receipt_ops%rowtype;r jsonb;pay payments%rowtype;funded numeric;allocated numeric;extra numeric;
begin
 if tid is null or not tenant_active() or not exists(select 1 from tenants where id=tid and shop_type='mobile') then raise exception 'mobile tenant inactive';end if;
 if not(has_shop_perm('invoice') or has_shop_perm('customers')) then raise exception 'no permission';end if;
 if pid is null or length(pid)<8 or length(pid)>100 or a is null or a<=0 or a>1000000000 or a<>round(a,2) then raise exception 'invalid receipt';end if;
 perform pg_advisory_xact_lock(hashtextextended(tid::text||pid,0));
 select * into old from mobile_receipt_ops where tenant_id=tid and id=pid;
 if found then if old.request<>p or old.actor<>auth.uid() then raise exception 'receipt conflict';end if;return old.result;end if;
 -- Serialize all receipts for this customer, including distinct operation IDs.
 perform 1 from customers where tenant_id=tid and id=cid and not coalesce(deleted,false) for update;
 if not found then raise exception 'customer missing';end if;
 if exists(select 1 from payments where id=pid and tenant_id=tid) then raise exception 'payment id conflict';end if;
 select coalesce(sum(total-paid),0) into bal from invoices where tenant_id=tid and customer_id=cid;
 select bal-coalesce(sum(amount),0) into bal from payments where tenant_id=tid and party_type='c' and party_id=cid and kind='in';
 if a>round(bal,2) then raise exception 'amount exceeds customer balance';end if;
 if ct is not null then
  select * into c from installment_contracts where tenant_id=tid and id=ct and not coalesce(deleted,false) for update;
  if not found or c.data->>'customerId' is distinct from cid then raise exception 'contract mismatch';end if;
  if not exists(select 1 from invoices where tenant_id=tid and id=c.data->>'invoiceId' and customer_id=cid) then raise exception 'invoice missing';end if;
  if p->'expectedSchedule' is distinct from c.data->'schedule' then raise exception 'contract changed, refresh';end if;
  -- A pre-upgrade receipt may have saved while its old schedule snapshot is still offline.
  -- Use real uniquely matched receipts as a paid floor before adding this receipt.
  select coalesce(sum(amount),0) into funded from payments where tenant_id=tid and kind='in' and party_type='c' and party_id=cid and (contract_id=ct or (contract_id is null and note='قسط عقد تقسيط #'||(c.data->>'invoiceNum') and (select count(*) from installment_contracts z where z.tenant_id=tid and not z.deleted and z.data->>'customerId'=cid and z.data->>'invoiceNum'=c.data->>'invoiceNum')=1));
  select coalesce(sum(coalesce((v->>'paidAmt')::numeric,0)),0) into allocated from jsonb_array_elements(c.data->'schedule')v;
  extra:=greatest(0,funded-allocated);
  if extra>0 then
   for x in select value from jsonb_array_elements(c.data->'schedule') loop
    need:=greatest(0,(x->>'amt')::numeric-coalesce((x->>'paidAmt')::numeric,0));take:=least(need,extra);extra:=extra-take;
    if take>0 then x:=x||jsonb_build_object('paidAmt',coalesce((x->>'paidAmt')::numeric,0)+take);if take=need then x:=x||jsonb_build_object('paidAt',now());end if;end if;
    sc:=sc||jsonb_build_array(x);
   end loop;
   if extra>0 then raise exception 'legacy receipts exceed contract';end if;
   c.data:=jsonb_set(c.data,'{schedule}',sc);sc:='[]'::jsonb;
  end if;
  select coalesce(sum(greatest(0,(v->>'amt')::numeric-coalesce((v->>'paidAmt')::numeric,0))),0) into leftamt from jsonb_array_elements(c.data->'schedule') v;
  if a>round(leftamt,2) then raise exception 'amount exceeds contract balance';end if;
  remaining:=a;
  for x in select value from jsonb_array_elements(c.data->'schedule') loop
   need:=greatest(0,(x->>'amt')::numeric-coalesce((x->>'paidAmt')::numeric,0));take:=least(need,remaining);remaining:=remaining-take;
   if take>0 then x:=x||jsonb_build_object('paidAmt',coalesce((x->>'paidAmt')::numeric,0)+take);if take=need then x:=x||jsonb_build_object('paidAt',now());end if;end if;
   sc:=sc||jsonb_build_array(x);
  end loop;
  perform set_config('mahal.atomic_receipt','yes',true);
  update installment_contracts set data=jsonb_set(data,'{schedule}',sc),updated_at=now() where id=ct and tenant_id=tid;
 end if;
 if coalesce(p->>'method','') not in('كاش','إنستاباي','فودافون كاش','تحويل بنكي') then raise exception 'invalid method';end if;
 perform set_config('mahal.atomic_receipt','yes',true);
 insert into payments(id,tenant_id,date,kind,party_type,party_id,amount,note,method,contract_id,created_by) values(pid,tid,coalesce((p->>'receiptDate')::timestamptz,now()),'in','c',cid,a,left(coalesce(p->>'note',''),500),p->>'method',ct,auth.uid()) returning * into pay;
 r:=jsonb_build_object('payment',to_jsonb(pay),'contract',case when ct is not null then (select data from installment_contracts where id=ct and tenant_id=tid) else null end,'balance',round(bal-a,2));
 insert into mobile_receipt_ops values(tid,pid,auth.uid(),p,r);return r;
end $$;
revoke all on function public.mobile_receive_payment(jsonb) from public,anon;
grant execute on function public.mobile_receive_payment(jsonb) to authenticated;
-- Once atomic receipts exist, an old offline contract snapshot must not erase allocations.
create or replace function public.guard_mobile_receipt_schedule() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if TG_OP='DELETE' then if exists(select 1 from payments where tenant_id=old.tenant_id and contract_id=old.id) then raise exception 'contract has receipts';end if;return old;end if;
 if coalesce(current_setting('mahal.atomic_receipt',true),'')<>'yes' and exists(select 1 from payments where tenant_id=old.tenant_id and contract_id=old.id) and (new.data->'schedule' is distinct from old.data->'schedule' or new.deleted is distinct from old.deleted or new.data->>'customerId' is distinct from old.data->>'customerId' or new.data->>'invoiceId' is distinct from old.data->>'invoiceId' or new.data->>'total' is distinct from old.data->>'total') then raise exception 'contract has atomic receipts; refresh and use receipt action';end if;return new;
end $$;
drop trigger if exists guard_receipt_schedule on installment_contracts;
create trigger guard_receipt_schedule before update or delete on installment_contracts for each row execute function guard_mobile_receipt_schedule();
create or replace function public.guard_linked_payment() returns trigger language plpgsql set search_path=public as $$
begin
 if TG_OP='INSERT' then if new.contract_id is not null and coalesce(current_setting('mahal.atomic_receipt',true),'')<>'yes' then raise exception 'use atomic receipt action';end if;return new;end if;
 if old.contract_id is not null then raise exception 'linked receipt is immutable';end if;
 if TG_OP='UPDATE' and new.contract_id is distinct from old.contract_id then raise exception 'receipt link is immutable';end if;
 if TG_OP='DELETE' then return old;end if;return new;
end $$;
drop trigger if exists guard_linked_payment on payments;
create trigger guard_linked_payment before insert or update or delete on payments for each row execute function guard_linked_payment();
notify pgrst,'reload schema';
commit;
