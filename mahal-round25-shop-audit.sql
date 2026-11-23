-- LOCAL DEVELOPMENT ONLY. Apply only after explicit rollout approval.
-- Audit is tenant-bound and server-attributed. No passwords, bearer tokens or backup contents.
begin;
create table if not exists public.shop_control(
 tenant_id uuid primary key references public.tenants(id),generation bigint not null default 1,
 updated_at timestamptz not null default now());
insert into public.shop_control(tenant_id) select id from public.tenants on conflict do nothing;
create or replace function public.shop_control_initialize() returns trigger language plpgsql security definer set search_path=public as $$begin insert into shop_control(tenant_id) values(NEW.id) on conflict do nothing;return NEW;end $$;
revoke all on function public.shop_control_initialize() from public,anon,authenticated;
drop trigger if exists mahal_shop_control on public.tenants;
create trigger mahal_shop_control after insert on public.tenants for each row execute function shop_control_initialize();
alter table public.shop_control enable row level security;
revoke all on public.shop_control from public,anon,authenticated;
grant select on public.shop_control to authenticated;
drop policy if exists shop_control_read on public.shop_control;
create policy shop_control_read on public.shop_control for select to authenticated using(tenant_id=my_tenant());
create table if not exists public.shop_audit(
 id bigint generated always as identity primary key,tenant_id uuid not null references public.tenants(id),
 transaction_id bigint not null default txid_current(),event_at timestamptz not null default now(),
 actor_id uuid,actor_name text not null,table_name text not null,row_id text,action text not null,
 before_row jsonb,after_row jsonb,reason text,source_event bigint references public.shop_audit(id),
 unique(source_event));
create index if not exists shop_audit_tenant_time on public.shop_audit(tenant_id,id desc);
alter table public.shop_audit enable row level security;
revoke all on public.shop_audit from public,anon,authenticated;
-- No direct SELECT: the owner-only RPC checks active tenant as well as identity.
create or replace function public.shop_owner_required() returns uuid language plpgsql stable security definer set search_path=public as $$
declare t uuid:=my_tenant();begin
 if t is null or not tenant_active() or not exists(select 1 from shop_users where tenant_id=t and auth_id=auth.uid() and owner and active) then raise exception 'active shop owner required';end if;return t;end $$;
revoke all on function public.shop_owner_required() from public,anon;
grant execute on function public.shop_owner_required() to authenticated;
create or replace function public.shop_generation_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare t uuid;g bigint;h jsonb;v text;j jsonb;begin
 -- SECURITY DEFINER's current_user is always the function owner, not the caller.
 -- Only a service JWT (or local DB maintenance without a JWT) bypasses the header.
 begin j:=coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb;exception when others then j:='{}';end;
 v:=coalesce(nullif(current_setting('request.jwt.claim.role',true),''),j->>'role');
 if auth.uid() is null and (v='service_role' or (v is null and session_user in('postgres','supabase_admin'))) then return case when TG_OP='DELETE' then OLD else NEW end;end if;
 t:=case when TG_OP='DELETE' then OLD.tenant_id else NEW.tenant_id end;
 if TG_OP='UPDATE' and OLD.tenant_id<>NEW.tenant_id then raise exception 'tenant immutable';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text,0));
 select generation into g from shop_control where tenant_id=t;
 if coalesce(g,1)>1 and coalesce(current_setting('mahal.internal_write',true),'')<>'yes' then
  begin h:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;exception when others then h:='{}';end;
  v:=h->>'x-mahal-generation';
  if v is null or v<>g::text then raise exception 'shop generation changed: reconnect and reload';end if;
 end if;
 return case when TG_OP='DELETE' then OLD else NEW end;
end $$;
create or replace function public.shop_actor_stamp() returns trigger language plpgsql security definer set search_path=public as $$
declare n text;begin
 select name into n from shop_users where auth_id=auth.uid() and tenant_id=NEW.tenant_id and active;
 n:=coalesce(nullif(n,''),'غير معروف');
 if TG_OP='INSERT' then NEW.created_actor_id:=auth.uid();NEW.created_actor_name:=n;
 else NEW.created_actor_id:=OLD.created_actor_id;NEW.created_actor_name:=OLD.created_actor_name;end if;
 NEW.updated_actor_id:=auth.uid();NEW.updated_actor_name:=n;return NEW;
end $$;
create or replace function public.shop_audit_capture() returns trigger language plpgsql security definer set search_path=public as $$
declare b jsonb;a jsonb;t uuid;n text;op text;rid text;begin
 if coalesce(current_setting('mahal.skip_audit',true),'')='yes' then return null;end if;
 if TG_OP<>'INSERT' then b:=to_jsonb(OLD);end if;if TG_OP<>'DELETE' then a:=to_jsonb(NEW);end if;
 if TG_TABLE_NAME='shop_users' then b:=b-'pin_h'-'password'-'password_hash';a:=a-'pin_h'-'password'-'password_hash';end if;
 if TG_OP='UPDATE' and (a-'updated_at'-'updated_actor_id'-'updated_actor_name')=(b-'updated_at'-'updated_actor_id'-'updated_actor_name') then return null;end if;
 t:=coalesce((a->>'tenant_id')::uuid,(b->>'tenant_id')::uuid);
 select name into n from shop_users where auth_id=auth.uid() and tenant_id=t;
 op:=case when TG_OP='DELETE' then 'delete' when TG_OP='INSERT' then 'create' when coalesce((a->>'deleted')::boolean,false) and not coalesce((b->>'deleted')::boolean,false) then 'delete' else 'update' end;
 rid:=coalesce(a->>'id',b->>'id');
 insert into shop_audit(tenant_id,actor_id,actor_name,table_name,row_id,action,before_row,after_row,reason)
 values(t,auth.uid(),coalesce(nullif(n,''),'غير معروف'),TG_TABLE_NAME,rid,op,b,a,nullif(current_setting('mahal.audit_reason',true),''));return null;
end $$;
do $$ declare t text;begin
 foreach t in array array['products','customers','suppliers','invoices','purchases','payments','movements','sales_returns','expenses','service_txns','day_closes','drawer_entries','shop_info','orders','devices','installment_contracts','repair_tickets','offers','shop_users','counters'] loop
  if to_regclass('public.'||t) is null then continue;end if;
  execute format('alter table public.%I add column if not exists created_actor_id uuid,add column if not exists created_actor_name text,add column if not exists updated_actor_id uuid,add column if not exists updated_actor_name text',t);
  execute format('drop trigger if exists mahal_generation on public.%I',t);
  execute format('drop trigger if exists mahal_actor on public.%I',t);
  execute format('drop trigger if exists mahal_audit on public.%I',t);
  execute format('create trigger mahal_generation before insert or update or delete on public.%I for each row execute function shop_generation_guard()',t);
  execute format('create trigger mahal_actor before insert or update on public.%I for each row execute function shop_actor_stamp()',t);
  execute format('create trigger mahal_audit after insert or update or delete on public.%I for each row execute function shop_audit_capture()',t);
 end loop;
end $$;
-- Old full-DB backups must also respect a wipe epoch, but never put their entire
-- contents into the audit log (recursive copies and private backup payloads).
do $$begin if to_regclass('public.backups') is not null then
 drop trigger if exists mahal_generation on public.backups;
 create trigger mahal_generation before insert or update or delete on public.backups for each row execute function shop_generation_guard();
end if;end $$;
create or replace function public.shop_audit_list(p_before bigint default null,p_actor uuid default null,p_table text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid:=shop_owner_required();begin
 return (select coalesce(jsonb_agg(to_jsonb(x) order by id desc),'[]') from
 (select id,event_at,actor_id,actor_name,table_name,row_id,action,reason,source_event,transaction_id,
 exists(select 1 from shop_audit z where z.source_event=shop_audit.id) as corrected
 from shop_audit where tenant_id=t and (p_before is null or id<p_before) and (p_actor is null or actor_id=p_actor) and (p_table is null or table_name=p_table) order by id desc limit 50)x);
end $$;
create or replace function public.shop_audit_detail(p_id bigint) returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid:=shop_owner_required();begin return(select to_jsonb(a) from shop_audit a where tenant_id=t and id=p_id);end $$;
-- Safe first restoration surface: only tombstoned master data, never financial history.
-- Financial reversals need separate atomic domain handlers, not generic row rollback.
create or replace function public.shop_restore_deleted(p_id bigint,p_reason text) returns jsonb language plpgsql security definer set search_path=public as $$
declare t uuid:=shop_owner_required();e shop_audit%rowtype;cur jsonb;restored jsonb;aid bigint;begin
 perform pg_advisory_xact_lock(hashtextextended(t::text,0));
 select * into e from shop_audit where id=p_id and tenant_id=t for update;
 if not found or e.action<>'delete' or e.table_name not in('products','customers','suppliers') or e.before_row is null then raise exception 'manual domain correction required';end if;
 if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then raise exception 'reason required';end if;
 if exists(select 1 from shop_audit where source_event=p_id) then raise exception 'already restored';end if;
 execute format('select to_jsonb(x) from public.%I x where tenant_id=$1 and id=$2 for update',e.table_name) into cur using t,e.row_id;
 if e.after_row is null then
  if cur is not null then raise exception 'record already exists; refresh';end if;
 else
  if cur is distinct from e.after_row or not coalesce((cur->>'deleted')::boolean,false) then raise exception 'record changed; refresh';end if;
 end if;
 perform set_config('mahal.audit_reason',trim(p_reason),true);
 if e.after_row is null then
  execute format('insert into public.%I select (jsonb_populate_record(null::public.%I,$1)).* returning to_jsonb(%I.*)',e.table_name,e.table_name,e.table_name) into restored using e.before_row||jsonb_build_object('deleted',false,'updated_at',now());
 else
 execute format('update public.%I set deleted=false,updated_at=now() where tenant_id=$1 and id=$2 returning to_jsonb(%I.*)',e.table_name,e.table_name) into restored using t,e.row_id;
 end if;
 -- Add a linked immutable correction, in addition to the ordinary update event.
 insert into shop_audit(tenant_id,actor_id,actor_name,table_name,row_id,action,before_row,after_row,reason,source_event)
 values(t,auth.uid(),(select name from shop_users where auth_id=auth.uid() and tenant_id=t),e.table_name,e.row_id,'restore',cur,restored,trim(p_reason),p_id) returning id into aid;
 return jsonb_build_object('id',aid,'restored',restored);
end $$;
revoke all on function public.shop_generation_guard(),public.shop_actor_stamp(),public.shop_audit_capture() from public,anon,authenticated;
revoke all on function public.shop_audit_list(bigint,uuid,text),public.shop_audit_detail(bigint),public.shop_restore_deleted(bigint,text) from public,anon;
grant execute on function public.shop_audit_list(bigint,uuid,text),public.shop_audit_detail(bigint),public.shop_restore_deleted(bigint,text) to authenticated;
commit;
