-- REVIEW CANDIDATE ONLY. Do not run on a hosted database without direct approval.
-- Additive: no historical backfill, no price/date/status updates at installation.
begin;
select pg_advisory_xact_lock(hashtextextended('mahal-round33-agreement-balances',0));
do $$ begin
 if to_regclass('public.subscription_agreements') is not null then raise exception 'round33 already present; stop and inspect'; end if;
 if to_regprocedure('public.admin_subscription_action(jsonb)') is null or to_regprocedure('public.admin_dashboard()') is null then raise exception 'owner dashboard prerequisite missing';end if;
end $$;
create table public.subscription_agreements(
 id uuid primary key,tenant_id uuid not null references public.tenants(id),
 months integer not null check(months between 1 and 120),
 monthly_rate numeric(12,2) not null check(monthly_rate>=0 and monthly_rate<=1000000000),
 total numeric(15,2) generated always as (months*monthly_rate) stored,
 period_start date,period_end date,
 origin text not null check(origin in('opening','renewal')),
 note text not null check(length(btrim(note)) between 1 and 500),
 created_by uuid not null,created_at timestamptz not null default clock_timestamp(),
 unique(id,tenant_id),check(period_start is null or period_end is null or period_end>=period_start));
create table public.subscription_allocations(
 entry_id uuid primary key references public.subscription_entries(id),
 agreement_id uuid not null,tenant_id uuid not null,
 created_by uuid not null,created_at timestamptz not null default clock_timestamp(),
 foreign key(agreement_id,tenant_id) references public.subscription_agreements(id,tenant_id));
create index subscription_agreements_tenant on public.subscription_agreements(tenant_id,created_at desc,id desc);
create index subscription_allocations_agreement on public.subscription_allocations(agreement_id);
alter table public.subscription_agreements enable row level security;
alter table public.subscription_allocations enable row level security;
revoke all on public.subscription_agreements,public.subscription_allocations from public,anon,authenticated;
-- Only the owner-only functions below expose these records.
create function public.admin_agreement_dashboard() returns jsonb language plpgsql security definer set search_path=public as $$
declare d jsonb;
begin
 if not public.is_platform_admin() then raise exception 'not admin';end if;
 d:=public.admin_dashboard();
 return d||jsonb_build_object('balanceVersion',1,'agreements',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('paid',coalesce(x.paid,0)) order by a.created_at desc,a.id desc),'[]'::jsonb)
 from subscription_agreements a left join lateral(
 select sum(e.amount) paid from subscription_allocations l join subscription_entries e on e.id=l.entry_id
 where l.agreement_id=a.id and e.tenant_id=a.tenant_id and e.kind='payment'
 and not exists(select 1 from subscription_entries c where c.original_id=e.id and c.kind='correction')) x on true),
 'allocations',(select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb) from subscription_allocations l));
end $$;
create function public.admin_agreement_action(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare op uuid:=(p->>'id')::uuid;tid uuid:=(p->>'tenantId')::uuid;k text:=p->>'action';
 t tenants%rowtype;old platform_operations%rowtype;cur uuid;aid uuid;eid uuid;src subscription_entries%rowtype;
 a numeric;m integer;r jsonb;innerp jsonb;ids jsonb;
begin
 perform set_config('TimeZone','Africa/Cairo',true);
 if not public.is_platform_admin() then raise exception 'not admin';end if;
 if op is null or tid is null then raise exception 'operation/shop required';end if;
 perform pg_advisory_xact_lock(hashtextextended(op::text,0));
 select * into old from platform_operations where id=op;
 if found then if old.actor<>auth.uid() or old.request<>p then raise exception 'operation conflict';end if;return old.result;end if;
 select * into t from tenants where id=tid for update;if not found then raise exception 'shop missing';end if;
 if t.onboarding_state='invited' then raise exception 'activate shop first';end if;
 select id into cur from subscription_agreements where tenant_id=tid order by created_at desc,id desc limit 1;
 if (p->>'expectedAgreement')::uuid is distinct from cur then raise exception 'agreement changed, reload';end if;
 if k='opening_agreement' then
  if cur is not null then raise exception 'opening agreement already exists';end if;
  if coalesce((p->>'reviewed')::boolean,false)=false then raise exception 'explicit reconciliation required';end if;
  m:=(p->>'months')::integer;a:=(p->>'rate')::numeric;
  if m is null or m<1 or m>120 or a is null or a<0 or a>1000000000 or a<>round(a,2) or a::text='NaN' then raise exception 'invalid agreement';end if;
  if nullif(btrim(p->>'note'),'') is null then raise exception 'agreement reason required';end if;
  -- Dates describe the reviewed agreement, not an instruction to change access dates.
  insert into subscription_agreements(id,tenant_id,months,monthly_rate,period_start,period_end,origin,note,created_by)
  values(op,tid,m,a,nullif(p->>'periodStart','')::date,nullif(p->>'periodEnd','')::date,'opening',left(btrim(p->>'note'),500),auth.uid());
  aid:=op;ids:=coalesce(p->'entryIds','[]'::jsonb);
  if jsonb_typeof(ids)<>'array' then raise exception 'invalid receipt list';end if;
  for eid in select value::uuid from jsonb_array_elements_text(ids) loop
   select * into src from subscription_entries where id=eid and tenant_id=tid and kind='payment' for update;
   if not found or exists(select 1 from subscription_entries where original_id=eid and kind='correction') then raise exception 'receipt invalid or corrected';end if;
   insert into subscription_allocations(entry_id,agreement_id,tenant_id,created_by) values(eid,aid,tid,auth.uid());
  end loop;
  r:=jsonb_build_object('agreementId',aid,'subscriptionUnchanged',true);
 elsif k in('agreement_receipt','agreement_renew') then
  if exists(select 1 from subscription_agreements where id=cur and period_end is not null and period_end is distinct from t.sub_end) then raise exception 'subscription changed outside agreement flow; review required';end if;
  innerp:=p-'expectedAgreement';
  if k='agreement_receipt' then
   if cur is null then raise exception 'review opening agreement first';end if;
   aid:=cur;innerp:=jsonb_set(innerp,'{action}','"receipt"');
  else
   if cur is null then raise exception 'review opening agreement before renewal';end if;
   if t.monthly_price is null or t.monthly_price<0 then raise exception 'monthly rate required';end if;
   if (p->>'expectedRate')::numeric is distinct from t.monthly_price then raise exception 'rate changed, reload';end if;
   innerp:=jsonb_set(innerp-'expectedRate','{action}','"renew"');
  end if;
  -- Existing atomic/idempotent receipt and renewal validation stays in force.
  r:=public.admin_subscription_action(innerp);
  if k='agreement_renew' then
   aid:=op;
   insert into subscription_agreements(id,tenant_id,months,monthly_rate,period_start,period_end,origin,note,created_by)
   values(aid,tid,(p->>'months')::integer,t.monthly_price,greatest(coalesce(t.sub_end,current_date),current_date),(r->>'end')::date,'renewal','Renewal reviewed in owner panel',auth.uid());
  end if;
  if p ? 'amount' and p->>'amount' is not null then
   insert into subscription_allocations(entry_id,agreement_id,tenant_id,created_by) values(op,aid,tid,auth.uid());
  end if;
  r:=r||jsonb_build_object('agreementId',aid,'creditPolicy','retained_no_auto_transfer');
  -- The wrapped operation used the same id. Store the exact outer request for retries.
  update platform_operations set request=p,result=r where id=op;
  return r;
 else raise exception 'unknown agreement action';end if;
 insert into platform_operations(id,actor,request,result) values(op,auth.uid(),p,r);return r;
end $$;
revoke all on function public.admin_agreement_dashboard(),public.admin_agreement_action(jsonb) from public,anon;
grant execute on function public.admin_agreement_dashboard(),public.admin_agreement_action(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
