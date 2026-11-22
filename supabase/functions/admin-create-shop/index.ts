// admin-create-shop — تنشئ محل جديد كامل: حساب دخول + tenant + مستخدم مالك
// Deploy: supabase functions deploy admin-create-shop
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto), نحتاج نضيف SERVICE_ROLE يدويًا
// يستدعيها الأدمن من لوحة التحكم بتوكِن حسابه — نتحقق إنه platform_admin.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method', { status: 405 });
  const url = Deno.env.get('SUPABASE_URL')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;

  // مين اللي بيكلمنا؟
  const caller = createClient(url, anon, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return Response.json({ error: 'unauthenticated' }, { status: 401 });

  const admin = createClient(url, serviceKey);
  const { data: isAdmin } = await admin.from('platform_admins')
    .select('user_id').eq('user_id', user.id).maybeSingle();
  if (!isAdmin) return Response.json({ error: 'not admin' }, { status: 403 });

  const { name, owner_name, phone, email, password, months } = await req.json();
  if (!name || !email || !password) return Response.json({ error: 'missing fields' }, { status: 400 });

  // ١) حساب الدخول
  const { data: created, error: e1 } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
  });
  if (e1) return Response.json({ error: e1.message }, { status: 400 });

  // ٢) المحل
  const subEnd = new Date();
  subEnd.setMonth(subEnd.getMonth() + (months || 1));
  const { data: tenant, error: e2 } = await admin.from('tenants').insert({
    name, owner_name: owner_name || '', phone: phone || '',
    status: 'active',
    sub_start: new Date().toISOString().slice(0, 10),
    sub_end: subEnd.toISOString().slice(0, 10),
  }).select('id').single();
  if (e2) return Response.json({ error: e2.message }, { status: 400 });

  // ٣) المستخدم المالك
  const { error: e3 } = await admin.from('shop_users').insert({
    tenant_id: tenant.id,
    auth_id: created.user.id,
    name: owner_name || name,
    owner: true,
    active: true,
    perms: { orders: 1, invoice: 1, products: 1, customers: 1, suppliers: 1, settings: 1, del: 1, stats: 1 },
  });
  if (e3) return Response.json({ error: e3.message }, { status: 400 });

  return Response.json({ ok: true, tenant_id: tenant.id, email });
});
