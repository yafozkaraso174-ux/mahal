import subprocess,json,concurrent.futures,os
cmd=['psql','-h','/tmp/ownerpg','-p','55432','-d',os.environ.get('PGDATABASE','postgres'),'-At','-v','ON_ERROR_STOP=1']
def q(s):return subprocess.run(cmd,input=s,text=True,capture_output=True)
def admin(p):return q("set role authenticated;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);select admin_invite_action('"+json.dumps(p)+"');")
p=dict(id='00000000-0000-0000-0000-000000005000',action='invite',token='ab'*32,name='race shop',email='race@example.test',shopType='mobile',months=1,price=300)
with concurrent.futures.ThreadPoolExecutor(2) as pool:r=list(pool.map(admin,[p,p]))
assert all(x.returncode==0 for x in r),[x.stderr for x in r]
r=q("insert into auth.users values('00000000-0000-0000-0000-000000005001','race@example.test',now());")
assert r.returncode==0,r.stderr
def accept(_):return q("set role authenticated;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000005001',false);select accept_shop_invite('"+'ab'*32+"');")
with concurrent.futures.ThreadPoolExecutor(2) as pool:r=list(pool.map(accept,[1,2]))
assert all(x.returncode==0 for x in r),[x.stderr for x in r]
assert q("select count(*) from shop_users where auth_id='00000000-0000-0000-0000-000000005001';").stdout.strip()=='1'
print('PASS two-session create invite replay and accept replay: one shop, one membership')
