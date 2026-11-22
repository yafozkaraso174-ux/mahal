# Requires an isolated local PostgreSQL database seeded with mobile-schema.sql.
import subprocess,json,concurrent.futures
cmd=['psql','-h','/tmp/ownerpg','-p','55432','-d','mobile_races','-At','-v','ON_ERROR_STOP=1']
def query(sql):return subprocess.run(cmd,input=sql,text=True,capture_output=True)
def call(p):return query("set role authenticated;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);select record_payment('"+json.dumps(p,ensure_ascii=False)+"'::jsonb);")
p=dict(id='concurrent-old-1',partyId='c',partyType='c',kind='in',amount=1000,note='قسط عقد تقسيط #110',method='كاش')
with concurrent.futures.ThreadPoolExecutor(2) as pool:r=list(pool.map(call,[p,p]))
assert all(x.returncode==0 for x in r),[x.stderr for x in r]
assert query("select count(*) from payments;select data->'schedule'->0->>'paidAmt' from installment_contracts;").stdout.strip()=='1\n1000'
p1={**p,'id':'concurrent-old-2'};p2={**p,'id':'concurrent-old-3'}
with concurrent.futures.ThreadPoolExecutor(2) as pool:r=list(pool.map(call,[p1,p2]))
assert all(x.returncode==0 for x in r),[x.stderr for x in r]
assert query("select count(*) from payments;select data->'schedule'->0->>'paidAmt' from installment_contracts;").stdout.strip()=='3\n3000'
print('PASS real PostgreSQL two-session legacy replay and distinct receipts: no duplicate, no lost schedule update')
