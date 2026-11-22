-- Invitation workflow. LOCAL candidate until approved combined rollout.
begin;
alter table tenants add column if not exists onboarding_state text not null default 'active' check(onboarding_state in('active','invited'));
create table if not exists shop_invites(id uuid primary key,tenant_id uuid not null references tenants(id),email text not null,token_hash text not null unique,months int not null check(months in(1,3,6,12)),expires_at timestamptz not null,revoked_at timestamptz,accepted_at timestamptz,accepted_by uuid,created_by uuid not null,created_at timestamptz not null default now());
alter table shop_invites enable row level security;
revoke all on shop_invites from public,anon,authenticated;
create or replace function admin_invite_action(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare op uuid:=(p->>'id')::uuid;k text:=p->>'action';tid uuid;iv shop_invites%rowtype;old platform_operations%rowtype;r jsonb;tok text:=p->>'token';h text;m int;a numeric;em text;nm text;
begin
 if not is_platform_admin() then raise exception 'not admin';end if;
 if op is null then raise exception 'operation required';end if;
 perform pg_advisory_xact_lock(hashtextextended(op::text,0));
 select * into old from platform_operations where id=op;
 if found then if old.actor<>auth.uid() or old.request<>(p-'token'||case when p ? 'token' then jsonb_build_object('tokenHash',encode(sha256(convert_to(p->>'token','UTF8')),'hex')) else '{}'::jsonb end) then raise exception 'operation conflict';end if;return old.result;end if;
 if k in('invite','reissue') then
  if tok is null or tok!~'^[a-f0-9]{64}$' then raise exception 'invalid invite token';end if;h:=encode(sha256(convert_to(tok,'UTF8')),'hex');
 end if;
 if k='invite' then
  nm:=btrim(p->>'name');em:=lower(btrim(p->>'email'));m:=(p->>'months')::int;a:=(p->>'price')::numeric;
  if nm is null or length(nm)<1 or length(nm)>160 or em is null or em!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(em)>320 or m is null or m not in(1,3,6,12) or a is null or a<0 or a>1000000000 or a<>round(a,2) or coalesce(p->>'shopType','') not in('general','mobile') then raise exception 'invalid invitation';end if;
  if exists(select 1 from auth.users u join shop_users s on s.auth_id=u.id where lower(u.email)=em) then raise exception 'account already assigned';end if;
  insert into tenants(name,owner_name,phone,shop_type,status,sub_start,sub_end,monthly_price,onboarding_state) values(nm,left(coalesce(p->>'owner',''),160),left(coalesce(p->>'phone',''),40),p->>'shopType','suspended',null,null,a,'invited') returning id into tid;
  insert into shop_invites(id,tenant_id,email,token_hash,months,expires_at,created_by) values(op,tid,em,h,m,now()+interval '1 hour',auth.uid()) returning * into iv;
 elsif k in('reissue','revoke') then
  tid:=(p->>'tenantId')::uuid;perform 1 from tenants where id=tid and onboarding_state='invited' for update;if not found then raise exception 'shop already activated or missing';end if;
  select * into iv from shop_invites where tenant_id=tid order by created_at desc limit 1 for update;if not found then raise exception 'invite missing';end if;
  update shop_invites set revoked_at=coalesce(revoked_at,now()) where tenant_id=tid and accepted_at is null and revoked_at is null;
  if k='reissue' then insert into shop_invites(id,tenant_id,email,token_hash,months,expires_at,created_by) values(op,tid,iv.email,h,iv.months,now()+interval '1 hour',auth.uid()) returning * into iv;end if;
 else raise exception 'unknown action';end if;
 r:=jsonb_build_object('tenantId',tid,'expiresAt',iv.expires_at,'email',iv.email,'revoked',k='revoke');
 -- Never persist the bearer token, including in the operation journal.
 insert into platform_operations values(op,auth.uid(),p-'token'||case when h is null then '{}'::jsonb else jsonb_build_object('tokenHash',h) end,r,now());return r;
end $$;
-- Correct replay comparison hashes supplied token before comparing.
create or replace function shop_invite_info(p_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare iv shop_invites%rowtype;
begin
 if p_token is null or p_token!~'^[a-f0-9]{64}$' then return jsonb_build_object('valid',false);end if;
 select * into iv from shop_invites where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found or iv.revoked_at is not null or iv.accepted_at is not null or iv.expires_at<=now() then return jsonb_build_object('valid',false);end if;
 return (select jsonb_build_object('valid',true,'name',t.name,'owner',t.owner_name,'type',t.shop_type,'email',iv.email,'months',iv.months,'expiresAt',iv.expires_at) from tenants t where t.id=iv.tenant_id and t.onboarding_state='invited');
end $$;
create or replace function accept_shop_invite(p_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare iv shop_invites%rowtype;u auth.users%rowtype;t tenants%rowtype;enddate date;
begin
 perform set_config('TimeZone','Africa/Cairo',true);
 if auth.uid() is null then raise exception 'sign in required';end if;
 select * into u from auth.users where id=auth.uid() for update;
 if u.email_confirmed_at is null then raise exception 'confirm your email first';end if;
 select * into iv from shop_invites where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found then raise exception 'invite unavailable';end if;
 select * into t from tenants where id=iv.tenant_id for update;
 select si.* into iv from shop_invites si where si.id=iv.id for update;
 if iv.accepted_by=auth.uid() and iv.accepted_at is not null then return jsonb_build_object('tenantId',iv.tenant_id,'accepted',true);end if;
 if iv.accepted_at is not null or iv.revoked_at is not null or iv.expires_at<=now() then raise exception 'invite unavailable';end if;
 if lower(u.email)<>iv.email then raise exception 'invited email required';end if;
 select * into t from tenants where id=iv.tenant_id for update;
 if t.onboarding_state<>'invited' or exists(select 1 from shop_users where auth_id=auth.uid()) then raise exception 'account already assigned';end if;
 enddate:=(current_date+make_interval(months=>iv.months))::date;
 insert into shop_users(id,tenant_id,auth_id,name,owner,active,perms) values(gen_random_uuid()::text,t.id,u.id,coalesce(nullif(t.owner_name,''),t.name),true,true,'{"orders":1,"invoice":1,"products":1,"customers":1,"suppliers":1,"settings":1,"del":1,"stats":1}'::jsonb);
 insert into shop_info(tenant_id,id,shop_name,owner_name,phone) values(t.id,1,t.name,t.owner_name,t.phone);
 update tenants set onboarding_state='active',status='active',sub_start=current_date,sub_end=enddate,updated_at=now() where id=t.id;
 update shop_invites set accepted_at=now(),accepted_by=u.id where id=iv.id;
 return jsonb_build_object('tenantId',t.id,'accepted',true,'end',enddate);
end $$;
create or replace function admin_invite_list() returns jsonb language plpgsql security definer set search_path=public as $$
begin if not is_platform_admin() then raise exception 'not admin';end if;return (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select distinct on(tenant_id) tenant_id,email,expires_at,revoked_at,accepted_at from shop_invites order by tenant_id,created_at desc)x);end $$;
revoke all on function admin_invite_action(jsonb),admin_invite_list(),accept_shop_invite(text),shop_invite_info(text) from public,anon,authenticated;
grant execute on function admin_invite_action(jsonb),admin_invite_list(),accept_shop_invite(text) to authenticated;
grant execute on function shop_invite_info(text) to anon,authenticated;
-- Superseded insecure/direct provisioning and renewal routes are not part of the new UI.
revoke execute on function admin_attach_shop(jsonb),admin_extend_subscription(uuid,integer),admin_set_tenant_status(uuid,text),admin_finish_shop(uuid,text,text,text,text,integer,text) from authenticated;
notify pgrst,'reload schema';
commit;
