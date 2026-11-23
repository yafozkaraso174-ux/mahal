-- LOCAL ONLY. Reverse an unlinked, positive receipt with a new signed ledger entry.
-- Linked/ambiguous installments are refused, not guessed or silently unallocated.
begin;
alter table payments add column if not exists correction_of text;
create unique index if not exists payment_correction_once on payments(tenant_id,correction_of) where correction_of is not null;
drop trigger if exists mahal_correction on payments;
create trigger mahal_correction before insert or update or delete on payments for each row execute function shop_correction_guard();
create or replace function shop_correct_payment(p_id bigint,p_reason text) returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid:=shop_owner_required();e shop_audit%rowtype;p payments%rowtype;r payments%rowtype;aid bigint;ct int;begin
 perform pg_advisory_xact_lock(hashtextextended(t::text,0));
 select * into e from shop_audit where tenant_id=t and id=p_id for update;
 if not found or e.table_name<>'payments' or e.action<>'create' or e.after_row is null then raise exception 'payment creation required';end if;
 if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then raise exception 'reason required';end if;
 if exists(select 1 from shop_audit where source_event=p_id) then raise exception 'already corrected';end if;
 select * into p from payments where tenant_id=t and id=e.row_id for update;
 if not found or to_jsonb(p) is distinct from e.after_row or p.amount<=0 or p.correction_of is not null then raise exception 'payment changed';end if;
 if to_jsonb(p)->>'contract_id' is not null then raise exception 'linked installment receipt requires domain correction';end if;
 if to_regclass('public.installment_contracts') is not null then execute 'select count(*) from installment_contracts where tenant_id=$1 and not deleted and data->>''customerId''=$2' into ct using t,p.party_id;if ct>0 then raise exception 'installment ambiguity requires domain correction';end if;end if;
 if exists(select 1 from day_closes where tenant_id=t and day>=(p.date at time zone 'Africa/Cairo')::date) then raise exception 'closed day needs reviewed correction';end if;
 if not ((p.kind='in' and p.party_type='c') or (p.kind='out' and p.party_type='s')) or p.method not in('كاش','تحويل') then raise exception 'unsupported payment type';end if;
 perform set_config('mahal.compensating','yes',true);perform set_config('mahal.audit_reason',trim(p_reason),true);
 insert into payments(id,tenant_id,date,kind,party_type,party_id,amount,note,method,created_by,correction_of)
 values(gen_random_uuid()::text,t,now(),p.kind,p.party_type,p.party_id,-p.amount,'تصحيح: '||trim(p_reason),p.method,auth.uid(),p.id) returning * into r;
 insert into shop_audit(tenant_id,actor_id,actor_name,table_name,row_id,action,before_row,after_row,reason,source_event)
 values(t,auth.uid(),coalesce((select name from shop_users where auth_id=auth.uid() and tenant_id=t),'غير معروف'),'payments',r.id,'correction',to_jsonb(p),to_jsonb(r),trim(p_reason),p_id) returning id into aid;
 return jsonb_build_object('id',aid,'correction',to_jsonb(r));
end $$;
revoke all on function shop_correct_payment(bigint,text) from public,anon,authenticated;
grant execute on function shop_correct_payment(bigint,text) to authenticated;
commit;
