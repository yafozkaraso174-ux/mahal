-- LOCAL ONLY. Narrow compensating corrections. Never replay arbitrary financial rows.
begin;
alter table public.expenses add column if not exists correction_of text;
alter table public.drawer_entries add column if not exists correction_of text;
create unique index if not exists expense_correction_once on expenses(tenant_id,correction_of) where correction_of is not null;
create unique index if not exists drawer_correction_once on drawer_entries(tenant_id,correction_of) where correction_of is not null;
create or replace function shop_correction_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare ref text;begin
 if TG_OP='INSERT' then
  if NEW.correction_of is not null and coalesce(current_setting('mahal.compensating',true),'')<>'yes' then raise exception 'use correction action';end if;return NEW;
 end if;
 if OLD.correction_of is not null then raise exception 'correction immutable';end if;
 execute format('select id from %I where tenant_id=$1 and correction_of=$2 limit 1',TG_TABLE_NAME) into ref using OLD.tenant_id,OLD.id;
 if ref is not null then raise exception 'corrected original immutable';end if;
 if TG_OP='UPDATE' and NEW.correction_of is distinct from OLD.correction_of then raise exception 'correction link immutable';end if;
 return case when TG_OP='DELETE' then OLD else NEW end;
end $$;
drop trigger if exists mahal_correction on expenses;
create trigger mahal_correction before insert or update or delete on expenses for each row execute function shop_correction_guard();
drop trigger if exists mahal_correction on drawer_entries;
create trigger mahal_correction before insert or update or delete on drawer_entries for each row execute function shop_correction_guard();
create or replace function shop_correct_cash_event(p_id bigint,p_reason text) returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid:=shop_owner_required();e shop_audit%rowtype;cur jsonb;r jsonb;rid text:=gen_random_uuid()::text;n text;aid bigint;begin
 perform pg_advisory_xact_lock(hashtextextended(t::text,0));
 select * into e from shop_audit where id=p_id and tenant_id=t for update;
 if not found or e.action<>'create' or e.table_name not in('expenses','drawer_entries') or e.after_row is null or e.after_row->>'correction_of' is not null then raise exception 'domain correction required';end if;
 if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then raise exception 'reason required';end if;
 if exists(select 1 from shop_audit where source_event=p_id) then raise exception 'already corrected';end if;
 execute format('select to_jsonb(x) from %I x where tenant_id=$1 and id=$2 for update',e.table_name) into cur using t,e.row_id;
 if cur is distinct from e.after_row or coalesce((cur->>'amount')::numeric,0)<=0 then raise exception 'record changed';end if;
 if exists(select 1 from day_closes where tenant_id=t and day>=((cur->>'date')::timestamptz at time zone 'Africa/Cairo')::date) then raise exception 'closed day needs reviewed correction';end if;
 perform set_config('mahal.compensating','yes',true);perform set_config('mahal.audit_reason',trim(p_reason),true);
 if e.table_name='expenses' then
  insert into expenses(id,tenant_id,date,title,amount,method,note,created_by,correction_of)
  values(rid,t,now(),'تصحيح: '||(cur->>'title'),-(cur->>'amount')::numeric,cur->>'method',trim(p_reason),auth.uid(),e.row_id) returning to_jsonb(expenses.*) into r;
 else
  insert into drawer_entries(id,tenant_id,date,kind,label,amount,note,created_by,correction_of)
  values(rid,t,now(),case when cur->>'kind'='in' then 'out' else 'in' end,'تصحيح: '||(cur->>'label'),(cur->>'amount')::numeric,trim(p_reason),auth.uid(),e.row_id) returning to_jsonb(drawer_entries.*) into r;
 end if;
 select name into n from shop_users where tenant_id=t and auth_id=auth.uid();
 insert into shop_audit(tenant_id,actor_id,actor_name,table_name,row_id,action,before_row,after_row,reason,source_event)
 values(t,auth.uid(),coalesce(n,'غير معروف'),e.table_name,rid,'correction',cur,r,trim(p_reason),p_id) returning id into aid;
 return jsonb_build_object('id',aid,'correction',r);
end $$;
revoke all on function shop_correction_guard(),shop_correct_cash_event(bigint,text) from public,anon,authenticated;
grant execute on function shop_correct_cash_event(bigint,text) to authenticated;
commit;
