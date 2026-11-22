begin;
create or replace function public.admin_finish_shop(p_user uuid,p_email text,p_name text,p_owner text,p_phone text,p_months integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid;
begin
 if not public.is_platform_admin() then raise exception 'not admin'; end if;
 if p_months not in(1,3,6,12) or p_months is null then raise exception 'invalid months'; end if;
 if length(trim(p_name))<1 or length(p_name)>160 then raise exception 'invalid name'; end if;
 perform 1 from auth.users where id=p_user and lower(email)=lower(p_email) for update;
 if not found then raise exception 'account mismatch'; end if;
 if exists(select 1 from shop_users where auth_id=p_user) then raise exception 'account already assigned'; end if;
 insert into tenants(name,owner_name,phone,status,sub_start,sub_end)
 values(trim(p_name),left(p_owner,160),left(p_phone,40),'active',current_date,(current_date+make_interval(months=>p_months))::date)
 returning id into tid;
 insert into shop_users(id,tenant_id,auth_id,name,owner,active,perms)
 values(gen_random_uuid()::text,tid,p_user,coalesce(nullif(p_owner,''),p_name),true,true,
 '{"orders":1,"invoice":1,"products":1,"customers":1,"suppliers":1,"settings":1,"del":1,"stats":1}'::jsonb);
 insert into shop_info(tenant_id,id,shop_name,owner_name,phone) values(tid,1,p_name,p_owner,p_phone);
 return tid;
end $$;
revoke all on function public.admin_finish_shop(uuid,text,text,text,text,integer) from public,anon;
grant execute on function public.admin_finish_shop(uuid,text,text,text,text,integer) to authenticated;
NOTIFY pgrst,'reload schema';
commit;
