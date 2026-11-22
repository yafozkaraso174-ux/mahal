-- LOCAL ONLY. No production execution without separate rollout approval.
begin;
alter table public.tenants add column if not exists monthly_price numeric(12,2);
create table if not exists public.subscription_entries(
 id uuid primary key,tenant_id uuid not null references public.tenants(id),kind text not null check(kind in('payment','correction')),
 amount numeric(12,2) not null check(amount>0),received_on date not null,method text not null,
 reference text not null default '',note text not null default '',original_id uuid references public.subscription_entries(id),
 created_by uuid not null,created_at timestamptz not null default now(),
 check((kind='payment' and original_id is null) or (kind='correction' and original_id is not null and length(btrim(note))>0)));
create unique index if not exists subscription_one_correction on public.subscription_entries(original_id) where original_id is not null;
create table if not exists public.platform_operations(id uuid primary key,actor uuid not null,request jsonb not null,result jsonb not null,created_at timestamptz not null default now());
alter table public.subscription_entries enable row level security;
alter table public.platform_operations enable row level security;
revoke all on public.subscription_entries,public.platform_operations from anon,authenticated;
drop policy if exists admin_read_entries on public.subscription_entries;
create policy admin_read_entries on public.subscription_entries for select to authenticated using(public.is_platform_admin());
grant select on public.subscription_entries to authenticated;
create or replace function public.admin_dashboard() returns jsonb language plpgsql security definer set search_path=public as $$
begin
 perform set_config('TimeZone','Africa/Cairo',true);
 if not public.is_platform_admin() then raise exception 'not admin';end if;
 return jsonb_build_object('today',current_date,'shops',(select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('owner_email',(select u.email from auth.users u join shop_users su on su.auth_id=u.id where su.tenant_id=t.id and su.owner limit 1)) order by t.created_at),'[]'::jsonb) from tenants t),
 'entries',(select coalesce(jsonb_agg(to_jsonb(e) order by created_at desc),'[]'::jsonb) from subscription_entries e));
end $$;
create or replace function public.admin_subscription_action(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare op uuid:=(p->>'id')::uuid;tid uuid:=(p->>'tenantId')::uuid;k text:=p->>'action';a numeric;m int;nd date;t tenants%rowtype;r jsonb;old platform_operations%rowtype;src subscription_entries%rowtype;
begin
 perform set_config('TimeZone','Africa/Cairo',true);
 if not public.is_platform_admin() then raise exception 'not admin';end if;
 if op is null then raise exception 'operation required';end if;
 perform pg_advisory_xact_lock(hashtextextended(op::text,0));
 select * into old from platform_operations where id=op;
 if found then if old.actor<>auth.uid() or old.request<>p then raise exception 'operation conflict';end if;return old.result;end if;
 select * into t from tenants where id=tid for update;if not found then raise exception 'shop missing';end if;
 if k in('renew','receipt') then
 if k='renew' then
  if (not p ? 'amount' or p->>'amount' is null) and coalesce((p->>'noPayment')::boolean,false)=false then raise exception 'explicit no payment required';end if;
  m:=(p->>'months')::int;if m is null or m not in(1,3,6,12) then raise exception 'invalid months';end if;
  if t.sub_end is null and coalesce((p->>'startFinite')::boolean,false)=false then raise exception 'confirm open subscription';end if;
  if (p->>'expectedEnd')::date is distinct from t.sub_end then raise exception 'subscription changed, reload';end if;
  nd:=(greatest(coalesce(t.sub_end,current_date),current_date)+make_interval(months=>m))::date;
  if (p->>'expectedNewEnd')::date is distinct from nd then raise exception 'preview changed, reload';end if;
  update tenants set sub_end=nd,sub_start=coalesce(sub_start,current_date),updated_at=now() where id=tid;
  -- Deliberately do not reactivate a manually suspended shop.
  end if;
  if k='receipt' and (not p ? 'amount' or p->>'amount' is null) then raise exception 'amount required';end if;
  if p ? 'amount' and p->>'amount' is not null then
   a:=(p->>'amount')::numeric;if a<=0 or a>1000000000 or a<>round(a,2) then raise exception 'invalid amount';end if;
   if p->>'method' not in('cash','insta','vf','bank') or nullif(p->>'method','') is null or (p->>'receivedOn')::date is null or (p->>'receivedOn')::date>current_date then raise exception 'invalid receipt';end if;
   insert into subscription_entries(id,tenant_id,kind,amount,received_on,method,reference,note,created_by) values(op,tid,'payment',a,(p->>'receivedOn')::date,p->>'method',left(coalesce(p->>'reference',''),120),left(coalesce(p->>'note',''),500),auth.uid());
  end if;
  r:=jsonb_build_object('end',coalesce(nd,t.sub_end),'status',t.status);
 elsif k='status' then
  if p->>'status' not in('active','suspended') or nullif(p->>'status','') is null then raise exception 'bad status';end if;
  if p->>'expectedStatus' is distinct from t.status then raise exception 'status changed, reload';end if;
  if p->>'status'='active' and t.sub_end<current_date then raise exception 'renew expired subscription first';end if;
  if nullif(btrim(p->>'reason'),'') is null then raise exception 'reason required';end if;
  update tenants set status=p->>'status',updated_at=now() where id=tid;r:=jsonb_build_object('status',p->>'status');
 elsif k='correct' then
  select * into src from subscription_entries where id=(p->>'originalId')::uuid and tenant_id=tid and kind='payment' for update;
  if not found or nullif(btrim(p->>'reason'),'') is null then raise exception 'payment/reason required';end if;
  insert into subscription_entries(id,tenant_id,kind,amount,received_on,method,note,original_id,created_by) values(op,tid,'correction',src.amount,current_date,src.method,left(p->>'reason',500),src.id,auth.uid());
  r:=jsonb_build_object('corrected',src.id,'subscriptionUnchanged',true);
 elsif k='price' then
  a:=(p->>'price')::numeric;if a is null or a<0 or a>1000000000 or a<>round(a,2) then raise exception 'invalid price';end if;
  update tenants set monthly_price=a,updated_at=now() where id=tid;r:=jsonb_build_object('price',a);
 else raise exception 'unknown action';end if;
 insert into platform_operations(id,actor,request,result) values(op,auth.uid(),p,r);return r;
end $$;
revoke all on function public.admin_dashboard(),public.admin_subscription_action(jsonb) from public,anon;
grant execute on function public.admin_dashboard(),public.admin_subscription_action(jsonb) to authenticated;
create or replace function public.admin_attach_shop(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare op uuid:=(p->>'id')::uuid;old platform_operations%rowtype;u uuid;tid uuid;r jsonb;m int:=(p->>'months')::int;a numeric:=(p->>'price')::numeric;nm text:=btrim(p->>'name');em text:=lower(btrim(p->>'email'));typ text:=p->>'shopType';
begin
 perform set_config('TimeZone','Africa/Cairo',true);
 if not public.is_platform_admin() then raise exception 'not admin';end if;
 if op is null then raise exception 'operation required';end if;
 perform pg_advisory_xact_lock(hashtextextended(op::text,0));
 select * into old from platform_operations where id=op;
 if found then if old.actor<>auth.uid() or old.request<>p then raise exception 'operation conflict';end if;return old.result;end if;
 if (p->>'expectedDate')::date is distinct from current_date then raise exception 'date changed, reload';end if;
 if nm is null or length(nm)<1 or length(nm)>160 or em is null or length(em)>320 or position('@' in em)<2 then raise exception 'invalid name/email';end if;
 if m is null or m not in(1,3,6,12) or a is null or a<0 or a>1000000000 or a<>round(a,2) or typ is null or typ not in('general','mobile') then raise exception 'invalid subscription';end if;
 select id into u from auth.users where lower(email)=em and email_confirmed_at is not null for update;
 if not found then raise exception 'confirmed account required';end if;
 if exists(select 1 from shop_users where auth_id=u) then raise exception 'account already assigned';end if;
 insert into tenants(name,owner_name,phone,shop_type,sub_start,sub_end,monthly_price) values(nm,left(coalesce(p->>'owner',''),160),left(coalesce(p->>'phone',''),40),typ,current_date,(current_date+make_interval(months=>m))::date,a) returning id into tid;
 insert into shop_users(id,tenant_id,auth_id,name,owner,active,perms) values(gen_random_uuid()::text,tid,u,coalesce(nullif(p->>'owner',''),nm),true,true,'{"orders":1,"invoice":1,"products":1,"customers":1,"suppliers":1,"settings":1,"del":1,"stats":1}'::jsonb);
 insert into shop_info(tenant_id,id,shop_name,owner_name,phone) values(tid,1,nm,left(coalesce(p->>'owner',''),160),left(coalesce(p->>'phone',''),40));
 r:=jsonb_build_object('tenantId',tid,'end',(current_date+make_interval(months=>m))::date);
 insert into platform_operations(id,actor,request,result) values(op,auth.uid(),p,r);return r;
end $$;
revoke all on function public.admin_attach_shop(jsonb) from public,anon;
grant execute on function public.admin_attach_shop(jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
