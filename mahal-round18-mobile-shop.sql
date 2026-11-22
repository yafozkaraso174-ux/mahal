-- Round 18: mobile-shop type (additive only; the general/oils shop is untouched).
-- NOT APPLIED YET. Run once in the Supabase SQL editor, after the user approves.
-- Safe to re-run. Old app versions keep working: they never read the new column or tables.
begin;

-- 1) shop type per tenant (default 'general' = today's behaviour)
alter table public.tenants add column if not exists shop_type text not null default 'general';
alter table public.tenants drop constraint if exists tenants_shop_type_chk;
alter table public.tenants add constraint tenants_shop_type_chk check (shop_type in ('general','mobile'));

-- 2) provisioning: optional shop type (replaces the 6-argument version; old calls still work through the default)
drop function if exists public.admin_finish_shop(uuid,text,text,text,text,integer);
create or replace function public.admin_finish_shop(p_user uuid,p_email text,p_name text,p_owner text,p_phone text,p_months integer,p_shop_type text default 'general')
returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid;
begin
 if not public.is_platform_admin() then raise exception 'not admin'; end if;
 if p_months not in(1,3,6,12) or p_months is null then raise exception 'invalid months'; end if;
 if length(trim(p_name))<1 or length(p_name)>160 then raise exception 'invalid name'; end if;
 if p_shop_type is null or p_shop_type not in ('general','mobile') then raise exception 'invalid shop type'; end if;
 perform 1 from auth.users where id=p_user and lower(email)=lower(p_email) for update;
 if not found then raise exception 'account mismatch'; end if;
 if exists(select 1 from shop_users where auth_id=p_user) then raise exception 'account already assigned'; end if;
 insert into tenants(name,owner_name,phone,status,sub_start,sub_end,shop_type)
 values(trim(p_name),left(p_owner,160),left(p_phone,40),'active',current_date,(current_date+make_interval(months=>p_months))::date,p_shop_type)
 returning id into tid;
 insert into shop_users(id,tenant_id,auth_id,name,owner,active,perms)
 values(gen_random_uuid()::text,tid,p_user,coalesce(nullif(p_owner,''),p_name),true,true,
 '{"orders":1,"invoice":1,"products":1,"customers":1,"suppliers":1,"settings":1,"del":1,"stats":1}'::jsonb);
 insert into shop_info(tenant_id,id,shop_name,owner_name,phone) values(tid,1,p_name,p_owner,p_phone);
 return tid;
end $$;
revoke all on function public.admin_finish_shop(uuid,text,text,text,text,integer,text) from public,anon;
grant execute on function public.admin_finish_shop(uuid,text,text,text,text,integer,text) to authenticated;

-- 3) tables (same shape for all three: id + jsonb data; the app owns the fields)
create table if not exists public.devices(
  id text primary key,
  tenant_id uuid not null default public.my_tenant() references public.tenants(id),
  imei text not null default '',
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  inserted_at timestamptz not null default now());
create table if not exists public.installment_contracts(
  id text primary key,
  tenant_id uuid not null default public.my_tenant() references public.tenants(id),
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  inserted_at timestamptz not null default now());
create table if not exists public.repair_tickets(
  id text primary key,
  tenant_id uuid not null default public.my_tenant() references public.tenants(id),
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  inserted_at timestamptz not null default now());
-- plain (not unique) index on purpose: a unique IMEI rule would block the offline outbox if two phones
-- received the same IMEI offline. The app already rejects duplicate IMEIs.
create index if not exists devices_tenant_imei_idx on public.devices(tenant_id, imei);
create index if not exists devices_tenant_upd_idx on public.devices(tenant_id, updated_at);
create index if not exists contracts_tenant_upd_idx on public.installment_contracts(tenant_id, updated_at);
create index if not exists tickets_tenant_upd_idx on public.repair_tickets(tenant_id, updated_at);

-- 4) row level security: same tenant isolation and permission model as the other tables
do $$
declare t text;
begin
 foreach t in array array['devices','installment_contracts','repair_tickets'] loop
  execute format('alter table public.%I enable row level security', t);
  execute format('drop policy if exists "tenant read %1$s" on public.%1$I', t);
  execute format('drop policy if exists "tenant write %1$s" on public.%1$I', t);
  execute format('drop policy if exists "tenant update %1$s" on public.%1$I', t);
  execute format('drop policy if exists "tenant delete %1$s" on public.%1$I', t);
  execute format('create policy "tenant read %1$s" on public.%1$I for select to authenticated using (tenant_id = public.my_tenant())', t);
  execute format('create policy "tenant write %1$s" on public.%1$I for insert to authenticated with check (tenant_id = public.my_tenant() and (public.has_shop_perm(''invoice'') or public.has_shop_perm(''products'')) and public.tenant_active())', t);
  execute format('create policy "tenant update %1$s" on public.%1$I for update to authenticated using (tenant_id = public.my_tenant() and (public.has_shop_perm(''invoice'') or public.has_shop_perm(''products'')) and public.tenant_active()) with check (tenant_id = public.my_tenant() and (public.has_shop_perm(''invoice'') or public.has_shop_perm(''products'')) and public.tenant_active())', t);
  execute format('create policy "tenant delete %1$s" on public.%1$I for delete to authenticated using (tenant_id = public.my_tenant() and public.has_shop_perm(''del'') and public.tenant_active())', t);
  execute format('revoke all on public.%I from anon', t);
  execute format('grant select, insert, update, delete on public.%I to authenticated', t);
 end loop;
end $$;

-- 5) switch an EXISTING shop to the mobile type (manual, per shop; example only):
--    update public.tenants set shop_type='mobile' where id='<tenant uuid>';

NOTIFY pgrst,'reload schema';
commit;
