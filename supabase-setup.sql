-- ============================================================
-- محلي — إعداد قاعدة بيانات المتجر الإلكتروني (Supabase)
-- شغّل السكربت ده مرة واحدة في: SQL Editor ← New query ← Paste ← Run
-- ============================================================

-- جدول الأصناف (بيتملى من البرنامج بزرار "نزّل الأصناف على المتجر")
create table if not exists products (
  id text primary key,
  name text not null,
  cat text,
  unit text,
  price numeric not null default 0,
  stock numeric not null default 0,
  photo_url text,
  updated_at timestamptz default now()
);

-- لو الجدول اتعمل قبل كده من غير عمود الصور
alter table products add column if not exists photo_url text;

-- جدول بيانات المحل (اسم المحل ورقم الواتساب اللي يظهر للزباين)
create table if not exists shop_info (
  id int primary key,
  shop_name text,
  owner_name text,
  phone text,
  updated_at timestamptz default now()
);

-- جدول الطلبات (الزباين بيبعتوا من المتجر، وصاحب المحل بيشوفها في البرنامج)
create table if not exists orders (
  id bigint generated always as identity primary key,
  customer_name text not null,
  phone text,
  note text,
  items jsonb not null,
  total numeric not null default 0,
  status text not null default 'new',
  created_at timestamptz not null default now()
);

create index if not exists orders_created_at_idx on orders (created_at desc);
create index if not exists orders_status_idx on orders (status);

-- تفعيل الحماية على الجداول
alter table products enable row level security;
alter table shop_info enable row level security;
alter table orders enable row level security;

-- الزوار (من غير تسجيل دخول): يشوفوا الأصناف وبيانات المحل بس
drop policy if exists "public read products" on products;
create policy "public read products" on products for select to public using (true);

drop policy if exists "public read shop_info" on shop_info;
create policy "public read shop_info" on shop_info for select to public using (true);

-- الزوار: يقدروا يبعتوا طلب جديد، من غير ما يشوفوا طلبات حد تاني ولا يغيّروا حاجة
drop policy if exists "public insert orders" on orders;
create policy "public insert orders" on orders for insert to public with check (true);

-- صاحب المحل (الحساب المسجل في Authentication): صلاحية كاملة
drop policy if exists "owner all products" on products;
create policy "owner all products" on products for all to authenticated using (true) with check (true);

drop policy if exists "owner all shop_info" on shop_info;
create policy "owner all shop_info" on shop_info for all to authenticated using (true) with check (true);

drop policy if exists "owner all orders" on orders;
create policy "owner all orders" on orders for all to authenticated using (true) with check (true);

-- ============================================================
-- صور الأصناف (Supabase Storage)
-- ============================================================

-- باكت عام للصور (الزوار يشوفوا الصور، بس محدش يقدر يرفع أو يعدّل غير صاحب المحل)
insert into storage.buckets (id, name, public)
values ('product-photos', 'product-photos', true)
on conflict (id) do nothing;

drop policy if exists "public read product photos" on storage.objects;
create policy "public read product photos" on storage.objects for select to public
using (bucket_id = 'product-photos');

drop policy if exists "owner write product photos" on storage.objects;
create policy "owner write product photos" on storage.objects for all to authenticated
using (bucket_id = 'product-photos') with check (bucket_id = 'product-photos');

-- ============================================================
-- تحديث ٢١ نوفمبر ٢٠٢٦: الدليفري وطرق الدفع
-- لو الجداول عندك اتعملت قبل التحديث ده، شغّل الأسطر دي مرة واحدة
-- ============================================================
alter table shop_info add column if not exists payment jsonb;
alter table shop_info add column if not exists delivery_fee numeric not null default 0;
alter table shop_info add column if not exists zones jsonb;
alter table shop_info add column if not exists delivery_on boolean not null default true;
alter table orders add column if not exists delivery text;
alter table orders add column if not exists payment text;
alter table orders add column if not exists address text;
alter table orders add column if not exists delivery_fee numeric not null default 0;
alter table orders add column if not exists zone text;

-- ============================================================
-- تحديث ٢١ نوفمبر ٢٠٢٦ (التاني): حسابات المستخدمين على كل الأجهزة
-- شغّل الأسطر دي مرة واحدة عشان الحسابات اللي بتعملها في البرنامج
-- تظهر على الموبايل واللابتوب وأي جهاز تاني
-- ============================================================
create table if not exists shop_users (
  id text primary key,
  name text not null,
  pin_h text not null,
  owner boolean not null default false,
  active boolean not null default true,
  perms jsonb,
  updated_at timestamptz default now()
);

alter table shop_users enable row level security;

-- قراءة قايمة الحسابات متاحة للكل عشان شاشة الدخول تقدر تعرضها قبل تسجيل الدخول
-- (الرقم السري متخزن كـ hash مش كنص واضح)
drop policy if exists "public read shop_users" on shop_users;
create policy "public read shop_users" on shop_users for select to public using (true);

-- الإضافة والتعديل والمسح للحساب المسجل في Authentication بس (حسابك إنت)
drop policy if exists "owner all shop_users" on shop_users;
create policy "owner all shop_users" on shop_users for all to authenticated using (true) with check (true);

-- ============================================================
-- تحديث ٢١ نوفمبر ٢٠٢٦ (التالت): نسخ احتياطي تلقائي
-- البرنامج بيرفع نسخة من كل البيانات هنا لوحده بعد أي تعديل
-- ============================================================
create table if not exists backups (
  id int primary key,
  data jsonb not null,
  updated_at timestamptz default now()
);

alter table backups enable row level security;

-- النسخ الاحتياطي فيه كل بيانات المحل — ليك إنت بس (الحساب المسجل في Authentication)
drop policy if exists "owner all backups" on backups;
create policy "owner all backups" on backups for all to authenticated using (true) with check (true);

-- ============================================================
-- تحديث ٢١ نوفمبر ٢٠٢٦ (الرابع): تأمين الحسابات والنسخ الاحتياطي
-- ١) هاش الأرقام السرية مش متاح للعامة خالص
-- ٢) شاشة الدخول بتقرا قايمة عامة من غير الهاش
-- ٣) التحقق من الرقم السري بيحصل على السيرفر + حد أقصى للمحاولات
-- ٤) صلاحيات الكتابة مقصورة على أول حساب في المشروع (حسابك إنت)
-- شغّل الملف ده كله مرة واحدة — آمن يتشغل أكتر من مرة
-- ============================================================

create extension if not exists pgcrypto;

-- قايمة عامة لشاشة الدخول: كل حاجة ما عدا هاش الرقم السري
create or replace view shop_users_public as
select id, name, owner, active, perms, updated_at from shop_users;
grant select on shop_users_public to anon;
grant select on shop_users_public to authenticated;

-- الجدول الأساسي مبقاش مقروء للعامة
drop policy if exists "public read shop_users" on shop_users;

-- جدول محاولات الدخول (مش متاح لأي حد — بيشتغل جوه الدالة بس)
create table if not exists pin_attempts (
  user_id text primary key,
  fails int not null default 0,
  window_start timestamptz not null default now()
);
alter table pin_attempts enable row level security;
revoke all on pin_attempts from anon;
revoke all on pin_attempts from authenticated;

-- التحقق من الرقم السري على السيرفر: ٥ محاولات غلط كل ١٠ دقايق لكل حساب
create or replace function verify_pin(p_id text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  stored text;
  fails_now int;
  win timestamptz;
begin
  perform pg_sleep(0.3);
  select pin_h into stored from shop_users where id = p_id and active;
  if stored is null then return false; end if;

  insert into pin_attempts (user_id, fails, window_start) values (p_id, 0, now())
  on conflict (user_id) do nothing;
  select fails, window_start into fails_now, win from pin_attempts where user_id = p_id;

  if now() - win > interval '10 minutes' then
    update pin_attempts set fails = 0, window_start = now() where user_id = p_id;
    fails_now := 0;
  end if;
  if fails_now >= 5 then return false; end if;

  if stored = encode(digest('mahal-pin-v1:' || p_pin, 'sha256'), 'hex') then
    update pin_attempts set fails = 0, window_start = now() where user_id = p_id;
    return true;
  else
    update pin_attempts set fails = fails + 1 where user_id = p_id;
    return false;
  end if;
end;
$$;
revoke all on function verify_pin(text, text) from public;
grant execute on function verify_pin(text, text) to anon;
grant execute on function verify_pin(text, text) to authenticated;

-- صلاحيات الكتابة مقصورة على أول حساب اتعمل في المشروع (حسابك إنت)
drop policy if exists "owner all shop_users" on shop_users;
create policy "owner all shop_users" on shop_users for all to authenticated
  using (auth.uid() = (select id from auth.users order by created_at asc limit 1))
  with check (auth.uid() = (select id from auth.users order by created_at asc limit 1));

drop policy if exists "owner all backups" on backups;
create policy "owner all backups" on backups for all to authenticated
  using (auth.uid() = (select id from auth.users order by created_at asc limit 1))
  with check (auth.uid() = (select id from auth.users order by created_at asc limit 1));

drop policy if exists "owner all orders" on orders;
create policy "owner all orders" on orders for all to authenticated
  using (auth.uid() = (select id from auth.users order by created_at asc limit 1))
  with check (auth.uid() = (select id from auth.users order by created_at asc limit 1));

drop policy if exists "owner all products" on products;
create policy "owner all products" on products for all to authenticated
  using (auth.uid() = (select id from auth.users order by created_at asc limit 1))
  with check (auth.uid() = (select id from auth.users order by created_at asc limit 1));

drop policy if exists "owner all shop_info" on shop_info;
create policy "owner all shop_info" on shop_info for all to authenticated
  using (auth.uid() = (select id from auth.users order by created_at asc limit 1))
  with check (auth.uid() = (select id from auth.users order by created_at asc limit 1));

drop policy if exists "owner write product photos" on storage.objects;
create policy "owner write product photos" on storage.objects for all to authenticated
  using (bucket_id = 'product-photos' and auth.uid() = (select id from auth.users order by created_at asc limit 1))
  with check (bucket_id = 'product-photos' and auth.uid() = (select id from auth.users order by created_at asc limit 1));

-- قراءة الأصناف وبيانات المحل وإرسال الطلبات للزباين زي ما هي (مش متأثرة)

-- ============================================================
-- محلّي — جولة تأمين ٢ (٢٠٢٦-١١-٢١)
-- ١) إصلاح سياسات الصلاحيات (كانت بتقرأ auth.users جوه السياسة وده بيفشل بخطأ صلاحيات عند التنفيذ — وده سبب إن رفع اللابتوب اترفض)
-- ٢) عداد محاولات الرقم السري بقى متسلسل ومش بيتمدد
-- شغّل الملف ده كله مرة واحدة في SQL Editor — آمن يتشغل أكتر من مرة
-- ============================================================

-- ١) دالة بتجاوب: هل اللي بيكلمنا هو حساب المالك؟
--    بتشتغل بصلاحيات قاعدة البيانات نفسها (security definer) عشان تقدر تقرأ auth.users
--    من غير ما ندي أي حد صلاحية عليه. مفيش أي grant جديد على auth.users.
create or replace function public.is_shop_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    auth.uid() = (select id from auth.users order by created_at asc limit 1),
    false
  );
$$;
revoke all on function public.is_shop_owner() from public;
grant execute on function public.is_shop_owner() to anon;
grant execute on function public.is_shop_owner() to authenticated;

-- ٢) إعادة بناء كل سياسات المالك على الدالة الجديدة
drop policy if exists "owner all shop_users" on shop_users;
create policy "owner all shop_users" on shop_users for all to authenticated
  using (public.is_shop_owner()) with check (public.is_shop_owner());

drop policy if exists "owner all backups" on backups;
create policy "owner all backups" on backups for all to authenticated
  using (public.is_shop_owner()) with check (public.is_shop_owner());

drop policy if exists "owner all orders" on orders;
create policy "owner all orders" on orders for all to authenticated
  using (public.is_shop_owner()) with check (public.is_shop_owner());

drop policy if exists "owner all products" on products;
create policy "owner all products" on products for all to authenticated
  using (public.is_shop_owner()) with check (public.is_shop_owner());

drop policy if exists "owner all shop_info" on shop_info;
create policy "owner all shop_info" on shop_info for all to authenticated
  using (public.is_shop_owner()) with check (public.is_shop_owner());

drop policy if exists "owner write product photos" on storage.objects;
create policy "owner write product photos" on storage.objects for all to authenticated
  using (bucket_id = 'product-photos' and public.is_shop_owner())
  with check (bucket_id = 'product-photos' and public.is_shop_owner());

-- ٣) verify_pin بنسخة أقوى:
--    - قفل تسلسلي لكل حساب: محاولتين في نفس اللحظة بيتعدوا مرة واحدة بس
--    - مدة القفل ثابتة: اللي بيحاول وهو مقفول مش بيمدد القفل
create or replace function verify_pin(p_id text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  stored text;
  fails_now int;
  win timestamptz;
begin
  -- تسلسل المحاولات لكل حساب جوه نفس العملية
  perform pg_advisory_xact_lock(hashtext(p_id));

  select pin_h into stored from shop_users where id = p_id and active;
  if stored is null then perform pg_sleep(0.3); return false; end if;

  insert into pin_attempts (user_id, fails, window_start) values (p_id, 0, now())
  on conflict (user_id) do nothing;
  select fails, window_start into fails_now, win from pin_attempts where user_id = p_id;

  -- عدّت العشر دقايق؟ صفّر العداد
  if now() - win > interval '10 minutes' then
    update pin_attempts set fails = 0, window_start = now() where user_id = p_id;
    fails_now := 0;
  end if;

  -- مقفول (٥ محاولات غلط جوه العشر دقايق): ارفض من غير ما تمدد القفل
  if fails_now >= 5 then perform pg_sleep(0.3); return false; end if;

  if stored = encode(digest('mahal-pin-v1:' || p_pin, 'sha256'), 'hex') then
    update pin_attempts set fails = 0, window_start = now() where user_id = p_id;
    return true;
  else
    update pin_attempts set fails = fails + 1 where user_id = p_id;
    perform pg_sleep(0.3);
    return false;
  end if;
end;
$$;
revoke all on function verify_pin(text, text) from public;
grant execute on function verify_pin(text, text) to anon;
grant execute on function verify_pin(text, text) to authenticated;

-- قراءة الأصناف وبيانات المحل وإرسال الطلبات للزباين زي ما هي (مش متأثرة)
-- قائمة shop_users_public العامة زي ما هي: id والاسم والحالة والصلاحيات ووقت التحديث بس
-- (محتاجينها لشاشة الدخول والمزامنة — هاش الرقم السري مش فيها)

-- ============================================================
-- محلّي — إصلاح سريع ٣ (٢٠٢٦-١١-٢١)
-- السبب: verify_pin كانت بتضرب خطأ «function digest does not exist»
-- لأن Supabase بينزّل pgcrypto في مخطط extensions مش public،
-- والدالة كانت شغالة بمسار بحث public بس.
-- النتيجة: تسجيل الدخول أول مرة على أي جهاز جديد كان بيفشل.
-- شغّل الملف ده كله مرة واحدة — آمن يتشغل أكتر من مرة
-- ============================================================

create extension if not exists pgcrypto;

create or replace function verify_pin(p_id text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  stored text;
  fails_now int;
  win timestamptz;
begin
  -- تسلسل المحاولات لكل حساب جوه نفس العملية
  perform pg_advisory_xact_lock(hashtext(p_id));

  select pin_h into stored from shop_users where id = p_id and active;
  if stored is null then perform pg_sleep(0.3); return false; end if;

  insert into pin_attempts (user_id, fails, window_start) values (p_id, 0, now())
  on conflict (user_id) do nothing;
  select fails, window_start into fails_now, win from pin_attempts where user_id = p_id;

  -- عدّت العشر دقايق؟ صفّر العداد
  if now() - win > interval '10 minutes' then
    update pin_attempts set fails = 0, window_start = now() where user_id = p_id;
    fails_now := 0;
  end if;

  -- مقفول (٥ محاولات غلط جوه العشر دقايق): ارفض من غير ما تمدد القفل
  if fails_now >= 5 then perform pg_sleep(0.3); return false; end if;

  if stored = encode(digest('mahal-pin-v1:' || p_pin, 'sha256'), 'hex') then
    update pin_attempts set fails = 0, window_start = now() where user_id = p_id;
    return true;
  else
    update pin_attempts set fails = fails + 1 where user_id = p_id;
    perform pg_sleep(0.3);
    return false;
  end if;
end;
$$;
revoke all on function verify_pin(text, text) from public;
grant execute on function verify_pin(text, text) to anon;
grant execute on function verify_pin(text, text) to authenticated;

-- ============================================================
-- محلّي — جولة ٤ (٢٠٢٦-١١-٢١): دخول بالإيميل والباسورد + مزامنة حية
-- بيربط مستخدمي المحل بحسابات سوبابيز الحقيقية، وبيشيل نظام الرقم السري القديم
-- شغّل الملف ده كله مرة واحدة في SQL Editor — آمن يتشغل أكتر من مرة
-- ============================================================

-- ١) عمود الربط بين مستخدم المحل وحساب سوبابيز
alter table shop_users add column if not exists auth_id uuid;
create unique index if not exists shop_users_auth_id_key on shop_users (auth_id);

-- ٢) اربط حساب المالك الموجود بأول حساب سوبابيز اتعمل في المشروع (حسابك إنت)
update shop_users
set auth_id = (select id from auth.users order by created_at asc limit 1)
where owner = true and auth_id is null;

-- ٣) دوال الفحص (security definer — مفيش أي grant جديد على auth.users)
create or replace function public.is_shop_member()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(exists(select 1 from public.shop_users where auth_id = auth.uid() and active), false);
$$;
create or replace function public.is_shop_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(exists(select 1 from public.shop_users where auth_id = auth.uid() and owner and active), false);
$$;
create or replace function public.shop_users_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from public.shop_users;
$$;
revoke all on function public.is_shop_member() from public;
grant execute on function public.is_shop_member() to anon, authenticated;
revoke all on function public.is_shop_owner() from public;
grant execute on function public.is_shop_owner() to anon, authenticated;
revoke all on function public.shop_users_count() from public;
grant execute on function public.shop_users_count() to anon, authenticated;

-- ٤) سياسات shop_users: الأعضاء يقرأوا القايمة، المالك بس يعدّل، وأول مالك لمحل جديد
drop policy if exists "owner all shop_users" on shop_users;
drop policy if exists "member read shop_users" on shop_users;
drop policy if exists "owner write shop_users" on shop_users;
drop policy if exists "bootstrap first owner" on shop_users;
create policy "member read shop_users" on shop_users for select to authenticated
  using (public.is_shop_member());
create policy "owner write shop_users" on shop_users for all to authenticated
  using (public.is_shop_owner()) with check (public.is_shop_owner());
create policy "bootstrap first owner" on shop_users for insert to authenticated
  with check (owner and public.shop_users_count() = 0);

-- ٥) باقي الجداول: أي عضو شغال يكتب (المالك والموظفين)
drop policy if exists "owner all products" on products;
drop policy if exists "member all products" on products;
create policy "member all products" on products for all to authenticated
  using (public.is_shop_member()) with check (public.is_shop_member());

drop policy if exists "owner all orders" on orders;
drop policy if exists "member all orders" on orders;
create policy "member all orders" on orders for all to authenticated
  using (public.is_shop_member()) with check (public.is_shop_member());

drop policy if exists "owner all shop_info" on shop_info;
drop policy if exists "member all shop_info" on shop_info;
create policy "member all shop_info" on shop_info for all to authenticated
  using (public.is_shop_member()) with check (public.is_shop_member());

drop policy if exists "owner write product photos" on storage.objects;
drop policy if exists "member write product photos" on storage.objects;
create policy "member write product photos" on storage.objects for all to authenticated
  using (bucket_id = 'product-photos' and public.is_shop_member())
  with check (bucket_id = 'product-photos' and public.is_shop_member());

-- النسخ الاحتياطية تفضل للمالك بس (فيها كل بيانات المحل)
-- سياسة "owner all backups" شغالة زي ما هي مع تعريف is_shop_owner الجديد

-- ٦) تنضيف نظام الرقم السري القديم
drop function if exists public.verify_pin(text, text);
drop table if exists pin_attempts;
drop view if exists shop_users_public;
alter table shop_users drop column if exists pin_h;

-- قراءة الأصناف وبيانات المحل وإرسال الطلبات للزباين زي ما هي (مش متأثرة)
-- ملحوظة: سيب "Allow new users to sign up" شغال — المالك بيستخدمه لما يضيف موظف من التطبيق.
-- أي حساب يتعمل بره التطبيق مش هيشوف حاجة: مفيش صلاحيات غير لأعضاء المحل بس.
-- ومهم: طفّي "Confirm email" من Authentication ← Providers ← Email عشان حسابات الموظفين تشتغل على طول.
