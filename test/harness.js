/* Mahal stage-2 sync harness: runs the real app script in jsdom against a mock Supabase. */
const fs=require('fs');
const {JSDOM}=require('jsdom'); // npm i jsdom

const html=fs.readFileSync(process.env.MAHAL_INDEX||require('path').join(__dirname,'..','index.html'),'utf8');
const m=html.match(/<script>([\s\S]*)<\/script>/);
if(!m){console.error('no script');process.exit(1);}
const appJS=m[1];

let PASS=0,FAIL=0;const failures=[];
function t(name,cond,extra){if(cond){PASS++;}else{FAIL++;failures.push(name+(extra?' :: '+extra:''));console.log('FAIL:',name,extra||'');}}
function eq(a,b){return JSON.stringify(a)===JSON.stringify(b);}

/* ---------- mock supabase ---------- */
function makeMock(){
 const tables={products:[],customers:[],suppliers:[],invoices:[],purchases:[],payments:[],movements:[],shop_users:[],backups:[],orders:[],shop_info:[]};
 let counter=1000;
 const json=(st,obj)=>({ok:st>=200&&st<300,status:st,headers:{get:()=>null},text:async()=>obj===undefined?'':JSON.stringify(obj),json:async()=>obj});
 function rows(table){return tables[table]||(tables[table]=[]);}
 function applyFilters(list,params){
  let out=list.slice();
  for(const [k,v] of params){
   if(k==='select'||k==='order'||k==='limit'||k==='on_conflict')continue;
   const mm=k.match(/^(.+)$/);const col=mm[1];
   if(v.startsWith('eq.'))out=out.filter(r=>String(r[col])===v.slice(3));
   else if(v.startsWith('gt.'))out=out.filter(r=>String(r[col]||'')>v.slice(3));
   else if(v.startsWith('not.in.('))out=out.filter(r=>!v.slice(8,-1).split(',').includes(String(r[col])));
  }
  return out;
 }
 async function handle(url,opt){
  opt=opt||{};
  const u=new URL(url);
  const path=u.pathname;
  const body=opt.body?JSON.parse(opt.body):null;
  const prefer=(opt.headers&&opt.headers.Prefer)||'';
  if(path.includes('/auth/v1/token'))return json(200,{access_token:'tok',refresh_token:'ref',expires_in:3600,user:{id:'owner-uid'}});
  if(path.includes('/auth/v1/signup'))return json(200,{id:'new-uid',user:{id:'new-uid'}});
  if(path.includes('/storage/v1/'))return json(200,{});
  if(path.includes('/rest/v1/rpc/')){
   const name=path.split('/rpc/')[1];
   if(name==='next_invoice_num')return json(200,++counter);
   if(name==='set_invoice_counter'){counter=Math.max(counter,body.v);return json(200,null);}
   if(name==='save_invoice'){const p=body.p;
    for(const it of p.items){const pr=tables.products.find(x=>x.id===it.productId);
     if(!pr)throw {status:400,obj:{message:'missing product '+it.productId}};
     if(pr.stock<it.qty)return json(400,{message:'shortage:'+it.name});
     pr.stock=Math.round((pr.stock-it.qty)*100)/100;
     tables.movements.push({id:it.moveId,pid:it.productId,kind:it.moveKind||'sale',qty:-it.qty,qty_before:pr.stock+it.qty,qty_after:pr.stock,ref:'فاتورة #'+p.num,date:p.date,inserted_at:new Date().toISOString()});}
    const num=p.num||++counter;counter=Math.max(counter,num);
    tables.invoices.push({id:p.id,num,date:p.date,customer_id:p.customerId,price_type:p.priceType,items:p.items,disc_pct:p.discPct||0,tax_pct:p.taxPct||0,disc_amt:p.discAmt||0,tax_amt:p.taxAmt||0,delivery_fee:p.deliveryFee||0,total:p.total,paid:p.paid,credit_used:p.creditUsed||0,updated_at:new Date().toISOString()});
    if(p.creditPaymentId)tables.payments.push({id:p.creditPaymentId,date:p.date,kind:'in',party_type:'c',party_id:p.customerId,amount:-(p.creditUsed||0),note:'رصيد',inserted_at:new Date().toISOString()});
    return json(200,{id:p.id,num});}
   if(name==='save_purchase'){const p=body.p;
    for(const it of p.items){const pr=tables.products.find(x=>x.id===it.productId);
     if(!pr)return json(400,{message:'missing product'});
     pr.stock=Math.round((pr.stock+it.qty)*100)/100;pr.cost=it.cost;
     tables.movements.push({id:it.moveId,pid:it.productId,kind:'in',qty:it.qty,qty_before:pr.stock-it.qty,qty_after:pr.stock,ref:'توريد',date:p.date,inserted_at:new Date().toISOString()});}
    tables.purchases.push({id:p.id,date:p.date,supplier_id:p.supplierId,items:p.items,total:p.total,paid:p.paid,updated_at:new Date().toISOString()});
    return json(200,{id:p.id});}
   if(name==='record_payment'){const p=body.p;
    tables.payments.push({id:p.id,date:p.date,kind:p.kind,party_type:p.partyType,party_id:p.partyId,amount:p.amount,note:p.note||'',inserted_at:new Date().toISOString()});
    return json(200,{id:p.id});}
   return json(404,{message:'unknown rpc'});
  }
  if(path.includes('/rest/v1/')){
   const table=decodeURIComponent(path.split('/rest/v1/')[1].split('?')[0]);
   if(!(table in tables))return json(404,{message:'no table '+table});
   if(!opt.method||opt.method==='GET'){
    let out=applyFilters(rows(table),u.searchParams);
    const ord=u.searchParams.get('order');
    if(ord){const [c,dir]=ord.split('.');out=out.slice().sort((a,b)=>String(a[c]||'')<String(b[c]||'')?-1:1);if(dir==='desc')out.reverse();}
    const lim=u.searchParams.get('limit');if(lim)out=out.slice(0,+lim);
    return json(200,out);}
   if(opt.method==='POST'){
    const arr=Array.isArray(body)?body:[body];const res=[];
    for(const row of arr){const ix=rows(table).findIndex(r=>String(r.id)===String(row.id));
     if(ix>=0){if(prefer.includes('merge-duplicates')){rows(table)[ix]=Object.assign(rows(table)[ix],row);res.push(rows(table)[ix]);}
      else if(!prefer.includes('ignore-duplicates'))return json(409,{message:'duplicate'});}
     else{rows(table).push(row);res.push(row);}}
    return json(201,prefer.includes('return=representation')?res:null);}
   if(opt.method==='PATCH'){
    const idp=u.searchParams.get('id');let n=0;
    if(idp&&idp.startsWith('eq.')){const id=idp.slice(3);
     rows(table).forEach((r,i)=>{if(String(r.id)===id){rows(table)[i]=Object.assign(r,body);n++;}});}
    return json(200,prefer.includes('return=minimal')?null:[{n}]);}
   if(opt.method==='DELETE'){
    const idp=u.searchParams.get('id');
    if(idp&&idp.startsWith('eq.'))tables[table]=rows(table).filter(r=>String(r.id)!==idp.slice(3));
    return json(200,null);}
  }
  return json(404,{message:'unhandled '+path});
 }
 return {tables,handle,getCounter:()=>counter};
}

/* ---------- boot ---------- */
const mock=makeMock();
const dom=new JSDOM(`<!doctype html><html><body><div id="app"></div><div id="overlay-root"></div><div id="print-area"></div></body></html>`,{url:'https://localhost/',runScripts:'outside-only',pretendToBeVisual:true});
const w=dom.window;

/* indexedDB stub */
const idbStore=new Map();
const req=(fn)=>{const r={};setTimeout(()=>{try{r.result=fn();r.onsuccess&&r.onsuccess();}catch(e){r.error=e;r.onerror&&r.onerror();}},0);return r;};
w.indexedDB={open:()=>{const r={};setTimeout(()=>{r.result={objectStoreNames:{contains:()=>true},transaction:()=>({objectStore:()=>({put:(v,k)=>{idbStore.set(k,v);},get:(k)=>req(()=>idbStore.get(k)||null),delete:(k)=>{idbStore.delete(k);}}),set oncomplete(f){setTimeout(f,0);},set onerror(f){}})},r.onsuccess&&r.onsuccess();},0);return r;}};
w.URL.createObjectURL=()=>'blob:mock';w.URL.revokeObjectURL=()=>{};
w.fetch=(url,opt)=>mock.handle(url,opt).catch(e=>{if(e&&e.status)return {ok:false,status:e.status,headers:{get:()=>null},text:async()=>JSON.stringify(e.obj),json:async()=>e.obj};throw e;});
w.print=()=>{};
Object.defineProperty(w.navigator,'onLine',{get:()=>true});

/* seed storage */
const seedDB={
 settings:{shopName:'محل البركة',ownerName:'اسماعيل',phone:'',migratedV2:true},
 products:[{id:'p1',name:'سكر',cat:'بقالة',unit:'كيلو',rPrice:30,wPrice:27,cost:25,stock:10,lowAt:2},
           {id:'p2',name:'أرز',cat:'بقالة',unit:'كيلو',rPrice:40,wPrice:36,cost:33,stock:5,lowAt:1}],
 customers:[{id:'c1',name:'أحمد',phone:'010',type:'w'}],
 suppliers:[{id:'s1',name:'مورد ١',phone:'011'}],
 invoices:[],purchases:[],payments:[],movements:[],drafts:[],users:[],nextNum:1001
};
const nowIso=new Date().toISOString();
w.localStorage.setItem('mahal_v1',JSON.stringify(seedDB));
w.localStorage.setItem('mahal_shop_cfg',JSON.stringify({url:'https://mock.supabase.co',anon:'anonkey'}));
w.localStorage.setItem('mahal_auth',JSON.stringify({access_token:'tok',refresh_token:'ref',expires_at:Math.floor(Date.now()/1000)+3600,uid:'owner-uid',email:'owner@x.com'}));
w.localStorage.setItem('mahal_sync_v1',JSON.stringify({decided:true,lastPull:nowIso,lastPush:nowIso}));
w.localStorage.setItem('mahal_sync2_v1',JSON.stringify({products:nowIso,customers:nowIso,suppliers:nowIso,invoices:nowIso,purchases:nowIso,payments:nowIso,movements:nowIso}));
w.sessionStorage.setItem('mahal_cur',JSON.stringify({id:'u1',name:'صاحب المحل',owner:true,authId:'owner-uid',perms:{}}));

const ctx=dom.getInternalVMContext();
const vm=require('vm');
vm.runInContext(appJS,ctx);

const ev=(c)=>vm.runInContext(c,ctx);const G=(n)=>ev(n);
const sleep=(ms)=>new Promise(r=>setTimeout(r,ms));

(async()=>{
 await sleep(50);
 const ENT=ev('ENT'),DB=ev('DB');
 const outbox=()=>JSON.parse(w.localStorage.getItem('mahal_outbox_v1')||'[]');

 /* 1. ENT round trips */
 t('ENT products roundtrip',(r=>r&&r.rPrice===30&&r.cost===25&&r.stock===10)(ENT.products.unmap(ENT.products.map(DB.products[0]))));
 t('ENT invoices roundtrip',(r=>r&&r.num===7&&r.customerId==='c1'&&r.total===100&&r.items.length===1)(ENT.invoices.unmap(ENT.invoices.map({id:'i0',num:7,date:nowIso,customerId:'c1',priceType:'w',items:[{productId:'p1',qty:1,price:27}],discPct:0,taxPct:0,discAmt:0,taxAmt:0,total:100,paid:50,creditUsed:0}))));
 t('ENT payments roundtrip',(r=>r&&r.partyId==='c1'&&r.amount===75)(ENT.payments.unmap(ENT.payments.map({id:'y0',date:nowIso,kind:'in',partyType:'c',partyId:'c1',amount:75,note:''}))));
 t('ENT movements roundtrip',(r=>r&&r.pid==='p1'&&r.qty===-2&&r.after===8)(ENT.movements.unmap(ENT.movements.map({id:'m0',pid:'p1',kind:'sale',qty:-2,before:10,after:8,ref:'x',date:nowIso}))));
 t('products map photo_url null w/o photo',ENT.products.map(DB.products[0]).photo_url===null);

 /* 2. invoice write path */
 ev(`invDraft={customerId:'c1',priceType:'w',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:4,price:27,cost:25}],paid:'108',disc:'',tax:'',useCredit:true}`);
 ev('saveInvoice(false)');
 await sleep(30);
 const inv=ev('DB.invoices[0]');
 t('invoice saved locally',!!inv&&inv.total===108&&inv.paid===108);
 t('invoice items moveId+moveKind',!!(inv&&inv.items[0].moveId&&inv.items[0].moveKind==='sale'));
 t('stock decremented locally',ev('DB.products[0].stock')===6);
 t('local movement logged with moveId',ev(`DB.movements.some(x=>x.id==='${inv.items[0].moveId}'&&x.qty===-4)`));
 const ob1=outbox();
 t('invoice op enqueued',ob1.length===1&&ob1[0].type==='invoice'&&ob1[0].payload.creditPaymentId===null);
 t('nextNum bumped',ev('DB.nextNum')===1002);

 /* 3. flush to server (server has no p1 yet -> shortage/missing -> failed op expected here) */
 await ev('flushOutbox()');await sleep(30);
 console.log('  note after first flush: outbox=',JSON.stringify(outbox().map(o=>({t:o.type,f:o.failed||null}))));

 /* seed server products so RPCs succeed */
 mock.tables.products.push({id:'p1',name:'سكر',cat:'بقالة',unit:'كيلو',price:30,wprice:27,cost:25,stock:10,lowat:2,deleted:false,updated_at:nowIso});
 mock.tables.products.push({id:'p2',name:'أرز',cat:'بقالة',unit:'كيلو',price:40,wprice:36,cost:33,stock:5,lowat:1,deleted:false,updated_at:nowIso});
 ev(`(function(){const o=outboxGet();o.forEach(x=>delete x.failed);outboxSet(o);})()`);
 await ev('flushOutbox()');await sleep(30);
 t('outbox empty after retry',outbox().length===0);
 t('server has invoice',mock.tables.invoices.length===1&&mock.tables.invoices[0].num===1001);
 t('server stock decremented',mock.tables.products.find(p=>p.id==='p1').stock===6);
 t('server movement recorded',mock.tables.movements.some(x=>x.pid==='p1'&&x.qty===-4));

 /* 4. purchase write path */
 ev(`purDraft={supplierId:'s1',items:[{productId:'p2',name:'أرز',unit:'كيلو',qty:10,cost:'33'}],paid:'330'}`);
 ev('savePurchase()');
 await sleep(30);
 const pur=ev('DB.purchases[0]');
 t('purchase saved locally',!!pur&&pur.total===330&&!!pur.items[0].moveId);
 t('purchase stock incremented locally',ev('DB.products[1].stock')===15&&ev('DB.products[1].cost')===33);
 await ev('flushOutbox()');await sleep(20);
 t('server has purchase',mock.tables.purchases.length===1);
 t('server purchase stock',mock.tables.products.find(p=>p.id==='p2').stock===15&&mock.tables.products.find(p=>p.id==='p2').cost===33);

 /* 5. payment write path */
 w.document.body.insertAdjacentHTML('beforeend','<select id="pay-party"><option value="c1" selected>c1</option></select><input id="pay-amt" value="50"><input id="pay-note" value="نقدي">');
 ev(`savePayment('in')`);
 await sleep(30);
 t('payment saved locally',ev('DB.payments.length')===1&&ev('DB.payments[0].amount')===50&&ev('DB.payments[0].kind')==='in');
 await ev('flushOutbox()');await sleep(20);
 t('server has payment',mock.tables.payments.length===1&&mock.tables.payments[0].amount===50);

 /* 6. pullDelta merges server changes */
 mock.tables.products.push({id:'p9',name:'زيت',cat:'بقالة',unit:'زجاجة',price:90,wprice:85,cost:80,stock:20,lowat:3,deleted:false,updated_at:new Date(Date.now()+1000).toISOString()});
 mock.tables.customers.push({id:'c9',name:'زبون جديد',phone:'012',type:'r',deleted:false,updated_at:new Date(Date.now()+1000).toISOString()});
 mock.tables.invoices.push({id:'ix9',num:1100,date:new Date().toISOString(),customer_id:'c9',price_type:'r',items:[{productId:'p9',qty:1,price:90}],disc_pct:0,tax_pct:0,disc_amt:0,tax_amt:0,delivery_fee:0,total:90,paid:90,credit_used:0,updated_at:new Date(Date.now()+1000).toISOString()});
 const ch=await ev('pullDelta(false)');await sleep(20);
 t('pullDelta reports change',ch===true);
 t('pulled product merged',!!ev(`DB.products.find(p=>p.id==='p9'&&p.stock===20&&p.cost===80)`));
 t('pulled customer merged',!!ev(`DB.customers.find(c=>c.id==='c9')`));
 t('pulled invoice merged',!!ev(`DB.invoices.find(i=>i.id==='ix9'&&i.num===1100)`));
 const s2=JSON.parse(w.localStorage.getItem('mahal_sync2_v1'));
 t('sync2 advanced',s2.invoices>nowIso);

 /* 7. soft delete propagation */
 mock.tables.products.find(p=>p.id==='p9').deleted=true;
 mock.tables.products.find(p=>p.id==='p9').updated_at=new Date(Date.now()+2000).toISOString();
 await ev('pullDelta(false)');await sleep(10);
 t('server softdel removes local row',!ev(`DB.products.find(p=>p.id==='p9')`));

 /* 8. perms gate */
 w.sessionStorage.setItem('mahal_cur',JSON.stringify({id:'u2',name:'موظف',owner:false,authId:'owner-uid',perms:{invoice:1,customers:1,orders:1,products:1}}));
 ev(`curUser=JSON.parse(sessionStorage.getItem('mahal_cur'))`);
 mock.tables.purchases.push({id:'px9',date:new Date().toISOString(),supplier_id:'s1',items:[],total:10,paid:10,updated_at:new Date(Date.now()+3000).toISOString()});
 const nPur=ev('DB.purchases.length');
 await ev('pullDelta(false)');await sleep(10);
 t('staff without suppliers perm skips purchases',ev('DB.purchases.length')===nPur);
 t('staff with invoice perm has invoices',!!ev(`DB.invoices.find(i=>i.id==='ix9')`));

 /* 9. shortage marks op failed */
 ev(`curUser={id:'u1',name:'o',owner:true,authId:'owner-uid',perms:{}}`);
 ev(`enqueue(${JSON.stringify({type:'invoice',table:'invoices',rowId:'bad1',payload:{id:'bad1',num:0,date:new Date().toISOString(),customerId:'c1',priceType:'w',items:[{productId:'p1',qty:999,price:27,moveId:'mm1',moveKind:'sale'}],discPct:0,taxPct:0,discAmt:0,taxAmt:0,total:100,paid:100,creditUsed:0,creditPaymentId:null}})})`);
 await sleep(50);await ev('flushOutbox()');await sleep(20);
 const bad=outbox().find(o=>o.rowId==='bad1');
 t('shortage op marked failed',!!(bad&&bad.failed&&String(bad.failed).startsWith('shortage:')));
 ev(`(function(){const o=outboxGet();outboxSet(o.filter(x=>x.rowId!=='bad1'));})()`);

 /* 10. RPC renum sync */
 ev(`DB.invoices.push({id:'i50',num:0,date:new Date().toISOString(),customerId:'c1',priceType:'w',items:[],total:27,paid:27,creditUsed:0})`);
 ev(`enqueue(${JSON.stringify({type:'invoice',table:'invoices',rowId:'i50',payload:{id:'i50',num:0,date:new Date().toISOString(),customerId:'c1',priceType:'w',items:[{productId:'p1',qty:1,price:27,moveId:'mm2',moveKind:'sale'}],discPct:0,taxPct:0,discAmt:0,taxAmt:0,total:27,paid:27,creditUsed:0,creditPaymentId:null}})})`);
 await ev('flushOutbox()');await sleep(20);
 const srv50=mock.tables.invoices.find(i=>i.id==='i50');
 t('server assigned num from counter',!!(srv50&&srv50.num>1001));
 t('local num updated from RPC response',ev(`DB.invoices.find(i=>i.id==='i50').num`)===(srv50&&srv50.num));

 /* 11. softdel op */
 ev(`enqueue(${JSON.stringify({type:'softdel',table:'products',rowId:'p2'})})`);
 await ev('flushOutbox()');await sleep(10);
 t('softdel sets deleted on server',mock.tables.products.find(p=>p.id==='p2').deleted===true);

 /* 12. movement upsert ignore-duplicates */
 ev(`enqueue(${JSON.stringify({type:'upsert',table:'movements',rowId:'mv1',prefer:'resolution=ignore-duplicates',row:{id:'mv1',pid:'p1',kind:'edit',qty:2,qty_before:6,qty_after:8,ref:'تعديل يدوي',date:new Date().toISOString()}})})`);
 await ev('flushOutbox()');await sleep(10);
 t('movement upserted to server',mock.tables.movements.some(x=>x.id==='mv1'));
 ev(`enqueue(${JSON.stringify({type:'upsert',table:'movements',rowId:'mv1',prefer:'resolution=ignore-duplicates',row:{id:'mv1',pid:'p1',kind:'edit',qty:99,qty_before:0,qty_after:99,ref:'dupe',date:new Date().toISOString()}})})`);
 await ev('flushOutbox()');await sleep(10);
 t('ignore-duplicates keeps original',mock.tables.movements.find(x=>x.id==='mv1').qty===2);

 /* 13. staff doSyncNow does not push blob */
 const bkBefore=mock.tables.backups.length;
 ev(`curUser={id:'u2',name:'m',owner:false,authId:'owner-uid',perms:{invoice:1}}`);
 await ev('doSyncNow()');await sleep(20);
 t('staff sync does not push blob backup',mock.tables.backups.length===bkBefore);

 /* 14. owner migrate path */
 ev(`curUser={id:'u1',name:'o',owner:true,authId:'owner-uid',perms:{}};DB.settings.migratedV2=false;`);
 await ev('migrateToTables()');await sleep(30);
 t('migrate pushes customers',mock.tables.customers.some(c=>c.id==='c1'));
 t('migrate pushes invoices',mock.tables.invoices.some(i=>i.num===1001));
 t('migrate sets counter',mock.getCounter()>=1001);
 t('migrate sets flag',ev('DB.settings.migratedV2')===true);


 /* 15. fresh device: demo/seed rows replaced by server state, nextNum from counter */
 w.localStorage.removeItem('mahal_sync2_v1');
 ev(`DB.customers.push({id:'demoC',name:'مطعم تجريبي',phone:'',type:'w'})`);
 ev(`DB.products.push({id:'demoP',name:'صنف تجريبي',cat:'',unit:'قطعة',rPrice:1,wPrice:1,cost:1,stock:3,lowAt:0})`);
 const chF=await ev('pullDelta(false)');await sleep(20);
 t('fresh pull reports change',chF===true);
 t('fresh pull clears demo customer',!ev(`DB.customers.find(c=>c.id==='demoC')`));
 t('fresh pull clears demo product',!ev(`DB.products.find(p=>p.id==='demoP')`));
 t('fresh pull brings server customer',!!ev(`DB.customers.find(c=>c.id==='c1')`));
 t('fresh pull brings server product',!!ev(`DB.products.find(p=>p.id==='p1')`));
 t('fresh pull sets nextNum from counter',ev('DB.nextNum')>1001);
 t('sync2 populated after fresh pull',!!w.localStorage.getItem('mahal_sync2_v1'));

 console.log('\n'+PASS+' passed, '+FAIL+' failed');
 if(FAIL){console.log('failures:',failures);process.exit(1);}
 process.exit(0);
})().catch(e=>{console.error('HARNESS ERROR',e);process.exit(2);});
