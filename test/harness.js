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
 const tables={products:[],customers:[],suppliers:[],invoices:[],purchases:[],payments:[],movements:[],shop_users:[],backups:[],orders:[],shop_info:[],sales_returns:[],expenses:[],drawer_entries:[],day_closes:[],service_txns:[]};
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
    tables.invoices.push({id:p.id,num,date:p.date,customer_id:p.customerId,price_type:p.priceType,items:p.items,disc_pct:p.discPct||0,tax_pct:p.taxPct||0,disc_amt:p.discAmt||0,tax_amt:p.taxAmt||0,delivery_fee:p.deliveryFee||0,total:p.total,paid:p.paid,credit_used:p.creditUsed||0,pay_method:p.payMethod||'كاش',updated_at:new Date().toISOString()});
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
    tables.payments.push({id:p.id,date:p.date,kind:p.kind,party_type:p.partyType,party_id:p.partyId,amount:p.amount,note:p.note||'',method:p.method||'كاش',inserted_at:new Date().toISOString()});
    return json(200,{id:p.id});}
   if(name==='next_return_num')return json(200,++counter);
   if(name==='save_return'){const p=body.p;
    if(tables.sales_returns.some(x=>x.id===p.id))return json(200,{id:p.id,num:tables.sales_returns.find(x=>x.id===p.id).num});
    for(const it of (p.items||[])){const pr=tables.products.find(x=>x.id===it.productId);
     if(pr){pr.stock=Math.round((pr.stock+it.qty)*100)/100;
      tables.movements.push({id:it.moveId||('rm'+it.productId),pid:it.productId,kind:'return',qty:it.qty,qty_before:pr.stock-it.qty,qty_after:pr.stock,ref:'مرتجع',date:p.date,inserted_at:new Date().toISOString()});}}
    const num=++counter;
    tables.sales_returns.push({id:p.id,num,date:p.date,invoice_id:p.invoiceId||null,invoice_num:p.invoiceNum||null,customer_id:p.customerId||null,items:p.items||[],total:p.total||0,refund_method:p.refundMethod||'كاش',note:p.note||'',updated_at:new Date().toISOString()});
    if(p.refundMethod==='رصيد'&&p.customerId)tables.payments.push({id:p.creditPaymentId||('cp'+p.id),date:p.date,kind:'in',party_type:'c',party_id:p.customerId,amount:-(p.total||0),note:'رصيد مرتجع',method:'رصيد',inserted_at:new Date().toISOString()});
    return json(200,{id:p.id,num});}
   if(name==='save_expense'){const p=body.p;
    tables.expenses.push({id:p.id,date:p.date,title:p.title||'',amount:p.amount||0,method:p.method||'كاش',note:p.note||'',updated_at:new Date().toISOString()});
    return json(200,{id:p.id});}
   if(name==='save_drawer_entry'){const p=body.p;
    tables.drawer_entries.push({id:p.id,date:p.date,kind:p.kind||'in',label:p.label||'',amount:p.amount||0,note:p.note||'',updated_at:new Date().toISOString()});
    return json(200,{id:p.id});}
   if(name==='close_day'){const p=body.p;
    tables.day_closes.push({id:p.id,day:p.day,closed_at:new Date().toISOString(),opening:p.opening||0,expected:p.expected||0,actual:p.actual||0,diff:p.diff||0,payload:p.payload||{},note:p.note||''});
    return json(200,{id:p.id});}
   if(name==='save_service_txn'){const p=body.p;
    tables.service_txns.push({id:p.id,date:p.date,kind:p.kind||'تحويل',service:p.service||'',amount:p.amount||0,fee:p.fee||0,customer_name:p.customerName||'',note:p.note||'',updated_at:new Date().toISOString()});
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
w.indexedDB={open:()=>{const r={};setTimeout(()=>{r.result={close(){},objectStoreNames:{contains:()=>true},transaction:()=>({objectStore:()=>({put:(v,k)=>{idbStore.set(k,v);},get:(k)=>req(()=>idbStore.get(k)||null),delete:(k)=>{idbStore.delete(k);}}),set oncomplete(f){setTimeout(f,0);},set onerror(f){}})},r.onsuccess&&r.onsuccess();},0);return r;}};
w.URL.createObjectURL=()=>'blob:mock';w.URL.revokeObjectURL=()=>{};
w.HTMLCanvasElement.prototype.getContext=function(){return {fillStyle:'',direction:'',textAlign:'',font:'',lineWidth:0,strokeStyle:'',setLineDash(){},beginPath(){},moveTo(){},lineTo(){},stroke(){},fillRect(){},fillText(){}};};
w.HTMLCanvasElement.prototype.toBlob=function(cb){cb(new w.Blob([]));};
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
// Unit fixtures install a validated role below; real login/tenant switching is tested separately.

const ctx=dom.getInternalVMContext();
const vm=require('vm');
vm.runInContext(appJS,ctx);

const ev=(c)=>vm.runInContext(c,ctx);const G=(n)=>ev(n);
const sleep=(ms)=>new Promise(r=>setTimeout(r,ms));
ev("curUser={id:'u1',name:'صاحب المحل',owner:true,authId:'owner-uid',perms:{}}");

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
 w.document.body.insertAdjacentHTML('beforeend','<select id="pay-party"><option value="c1" selected>c1</option></select><input id="pay-amt" value="50"><input id="pay-note" value="نقدي"><div id="pay-method"><button class="on" data-v="كاش"></button><button data-v="تحويل"></button></div>');
 ev(`savePayment('in')`);
 await sleep(30);
 t('payment saved locally',ev('DB.payments.length')===1&&ev('DB.payments[0].amount')===50&&ev('DB.payments[0].kind')==='in');
 t('payment defaults to cash method',ev('DB.payments[0].method')==='كاش');
 await ev('flushOutbox()');await sleep(20);
 t('server has payment',mock.tables.payments.length===1&&mock.tables.payments[0].amount===50);
 t('server payment has method',mock.tables.payments[0].method==='كاش');

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

 /* 16. stage-2: method roundtrips + expenses + day-close calc */
 t('ENT invoice carries payMethod',ENT.invoices.map({id:'i9',num:9,date:nowIso,customerId:'c1',priceType:'w',items:[],total:10,paid:10,payMethod:'تحويل'}).pay_method==='تحويل');
 t('ENT invoice unmap payMethod',ENT.invoices.unmap({id:'i9',num:9,date:nowIso,customer_id:'c1',price_type:'w',items:[],total:10,paid:10,pay_method:'تحويل'}).payMethod==='تحويل');
 t('ENT payment carries method',ENT.payments.map({id:'y9',date:nowIso,kind:'in',partyType:'c',partyId:'c1',amount:5,method:'تحويل'}).method==='تحويل');
 t('ENT expenses roundtrip',(r=>r&&r.title==='إيجار'&&r.amount===150&&r.method==='كاش')(ENT.expenses.unmap(ENT.expenses.map({id:'e0',date:nowIso,title:'إيجار',amount:150,method:'كاش',note:''}))));
 t('ENT returns roundtrip',(r=>r&&r.num===3&&r.refundMethod==='رصيد'&&r.total===60)(ENT.returns.unmap(ENT.returns.map({id:'r0',num:3,date:nowIso,invoiceId:'i1',invoiceNum:1001,customerId:'c1',items:[],total:60,refundMethod:'رصيد',note:''}))));
 t('ENT serviceTxns roundtrip',(r=>r&&r.kind==='تحويل'&&r.amount===1000&&r.fee===10&&r.customerPhone==='01012345678'&&r.network==='فودافون')(ENT.serviceTxns.unmap(ENT.serviceTxns.map({id:'st0',date:nowIso,kind:'تحويل',service:'كارت شحن',network:'فودافون',amount:1000,fee:10,customerName:'رضا',customerPhone:'01012345678',note:''}))));
 t('ENT drawer roundtrip',(r=>r&&r.kind==='out'&&r.amount===200)(ENT.drawer.unmap(ENT.drawer.map({id:'d0',date:nowIso,kind:'out',label:'سحب صاحب المحل',amount:200,note:''}))));
 t('ENT dayCloses roundtrip',(r=>r&&r.expected===1850&&r.diff===-30)(ENT.dayCloses.unmap(ENT.dayCloses.map({id:'dc0',day:'2026-11-22',closedAt:nowIso,opening:1000,expected:1850,actual:1820,diff:-30,payload:{},note:''}))));

 /* invoice with تحويل method reaches server */
 ev(`invDraft={customerId:'c1',priceType:'w',items:[{productId:'p2',name:'أرز',unit:'كيلو',qty:1,price:36,cost:33}],paid:'36',disc:'',tax:'',useCredit:true,payMethod:'تحويل'}`);
 ev('saveInvoice(false)');
 await sleep(30);
 const invT=ev('DB.invoices[DB.invoices.length-1]');
 t('local invoice has payMethod',invT&&invT.payMethod==='تحويل');
 await ev('flushOutbox()');await sleep(20);
 const srvT=mock.tables.invoices.find(i=>i.id===invT.id);
 t('server invoice has pay_method',srvT&&srvT.pay_method==='تحويل');

 /* expense write path */
 w.document.body.insertAdjacentHTML('beforeend','<input id="ex-title" value="إيجار المحل"><input id="ex-amt" value="150"><div id="ex-method"><button class="on" data-v="كاش"></button><button data-v="تحويل"></button></div><input id="ex-note" value="">');
 ev('saveExpense()');
 await sleep(30);
 t('expense saved locally',ev('DB.expenses.length')===1&&ev('DB.expenses[0].amount')===150&&ev('DB.expenses[0].method')==='كاش');
 await ev('flushOutbox()');await sleep(20);
 t('server has expense',mock.tables.expenses.length===1&&mock.tables.expenses[0].amount===150);

 /* dayCloseCalc on isolated day */
 ev(`DB.invoices.push({id:'dz1',num:2001,date:'2020-01-15T10:00:00.000Z',customerId:'c1',priceType:'w',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:2,price:30,cost:25}],total:60,paid:60,creditUsed:0,payMethod:'كاش'});
      DB.invoices.push({id:'dz2',num:2002,date:'2020-01-15T11:00:00.000Z',customerId:'c1',priceType:'w',items:[{productId:'p2',name:'أرز',unit:'كيلو',qty:1,price:40,cost:33}],total:40,paid:20,creditUsed:0,payMethod:'تحويل'});
      DB.payments.push({id:'dz3',date:'2020-01-15T12:00:00.000Z',kind:'in',partyType:'c',partyId:'c1',amount:15,note:'',method:'كاش'});
      DB.payments.push({id:'dz4',date:'2020-01-15T12:30:00.000Z',kind:'in',partyType:'c',partyId:'c1',amount:-5,note:'رصيد',method:'رصيد'});
      DB.expenses.push({id:'dz5',date:'2020-01-15T13:00:00.000Z',title:'نقل',amount:10,method:'كاش',note:''});
      DB.serviceTxns.push({id:'dz6',date:'2020-01-15T14:00:00.000Z',kind:'تحويل',service:'فودافون كاش',amount:1000,fee:10,customerName:'',note:''});`);
 const dc=ev(`dayCloseCalc('2020-01-15T00:00:00.000Z')`);
 t('dayClose sales+count',dc.sales===100&&dc.count===2,'sales='+dc.sales);
 t('dayClose cash split',dc.cash===75,'cash='+dc.cash);
 t('dayClose transfer split',dc.transfer===20,'transfer='+dc.transfer);
 t('dayClose excludes credit payments',dc.cash===75&&dc.transfer===20);
 t('dayClose debt',dc.debt===20,'debt='+dc.debt);
 t('dayClose expenses',dc.exp===10&&dc.expCash===10);
 t('dayClose profit',dc.profit===(2*(30-25)+(40-33)),'profit='+dc.profit);
 t('dayClose net = profit + fees - exp',dc.net===(17+10-10),'net='+dc.net);
 t('dayClose top product',dc.top&&dc.top.name==='سكر'&&dc.top.qty===2);
 t('dayCloseText contains shop name',ev('dayCloseText(dayCloseCalc(\'2020-01-15T00:00:00.000Z\'))').includes('محل البركة'));

 /* 17. stage-3: returns + debt reminder + invoice image */
 /* return part of invoice #1001 (p1, sold 4 @ 27 cost 25, local stock 6) */
 const inv1=ev(`DB.invoices.find(i=>i.num===1001)`);
 ev(`openReturnSheet('${inv1.id}')`);
 t('return sheet draft built',!!ev('retDraft')&&ev('retDraft.items.length')===1&&ev('retDraft.items[0].max')===4);
 ev('retQty(0,1);retQty(0,1)');
 t('retQty clamps at max',ev('retDraft.items[0].qty')===2);
 ev(`retDraft.refundMethod='رصيد'`);
 ev('saveReturn()');
 await sleep(30);
 const ret1=ev('DB.returns[0]');
 t('return saved locally',!!ret1&&ret1.total===54&&ret1.refundMethod==='رصيد');
 t('return restocks locally',ev(`DB.products.find(p=>p.id==='p1').stock`)===8);
 t('return movement logged',ev(`DB.movements.some(m=>m.kind==='return'&&m.qty===2&&m.pid==='p1')`));
 t('credit refund creates negative رصيد payment',ev(`DB.payments.some(p=>p.amount===-54&&p.method==='رصيد'&&p.partyId==='c1')`));
 await ev('flushOutbox()');await sleep(30);
 const srvRet=mock.tables.sales_returns.find(r=>r.id===ret1.id);
 t('server has return',!!srvRet&&srvRet.total===54);
 t('server restocked',mock.tables.products.find(p=>p.id==='p1').stock===8);
 t('server assigned return num',srvRet&&srvRet.num>1001);
 t('local return num synced back',ev('DB.returns[0].num')===(srvRet&&srvRet.num));
 t('server credit payment stored',mock.tables.payments.some(p=>p.amount===-54&&p.method==='رصيد'));
 /* second return exceeding remaining qty is blocked by max */
 ev(`openReturnSheet('${inv1.id}')`);
 t('return max reduced after first return',ev('retDraft.items[0].max')===2);
 ev('retQty(0,1);retQty(0,1);retQty(0,1)');
 t('retQty cannot exceed max',ev('retDraft.items[0].qty')===2);
 ev(`retDraft.refundMethod='كاش'`);
 ev('saveReturn()');
 await sleep(30);
 t('cash refund does NOT create payment',!ev(`DB.payments.some(p=>p.note&&p.note.includes('مرتجع')&&p.method!=='رصيد')`));
 ev('retDraft=null');

 /* returns hit the day-close calc: isolated day */
 ev(`DB.returns.push({id:'dr1',num:5,date:'2020-01-15T15:00:00.000Z',invoiceId:'dz1',invoiceNum:2001,customerId:'c1',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:1,price:30,cost:25}],total:30,refundMethod:'كاش',note:''})`);
 const dc2=ev(`dayCloseCalc('2020-01-15T00:00:00.000Z')`);
 t('dayClose cash reduced by cash refund',dc2.cash===45,'cash='+dc2.cash);
 t('dayClose profit reduced by return',dc2.profit===12,'profit='+dc2.profit);
 t('dayClose ret field',dc2.ret===30);

 /* debt reminder */
 t('debtWaText format',ev(`debtWaText({name:'رضوان'},800)`).includes('800')===false&&ev(`debtWaText({name:'رضوان'},800)`).includes('رضوان'));
 ev(`DB.invoices.push({id:'dd1',num:3001,date:'2020-01-10T10:00:00.000Z',customerId:'c1',priceType:'w',items:[],total:500,paid:100,creditUsed:0,payMethod:'كاش'})`);
 const since=ev(`custDebtSince('c1')`);
 t('custDebtSince finds oldest unpaid',since&&new Date(since).toISOString()==='2020-01-10T10:00:00.000Z');
 t('waLink builds for 01x phone',ev(`waLink('01012345678','hi')`).startsWith('https://wa.me/201012345678'));

 /* invoice canvas renders */
 const cv=ev(`invoiceCanvas(DB.invoices.find(i=>i.num===1001))`);
 t('invoice canvas sized',!!cv&&cv.width===820&&cv.height>400);

 /* ---- stage 4: drawer + services ---- */
 const D='2020-02-20',DZ=D+'T00:00:00.000Z';
 ev(`DB.dayCloses.push({id:'dc0',day:'2020-02-19',closedAt:'2020-02-19T21:00:00.000Z',opening:0,expected:1000,actual:990,diff:-10,payload:{},note:''})`);
 ev(`DB.invoices.push({id:'di1',num:4001,date:'${D}T10:00:00.000Z',customerId:'',priceType:'w',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:2,price:50,cost:40}],total:100,paid:100,creditUsed:0,payMethod:'كاش'})`);
 ev(`DB.invoices.push({id:'di2',num:4002,date:'${D}T10:30:00.000Z',customerId:'',priceType:'w',items:[],total:200,paid:200,creditUsed:0,payMethod:'تحويل'})`);
 ev(`DB.payments.push({id:'dp1',kind:'in',amount:50,method:'كاش',date:'${D}T11:00:00.000Z',customerId:'c1',note:''})`);
 ev(`DB.expenses.push({id:'de1',date:'${D}T12:00:00.000Z',title:'نقل',amount:30,method:'كاش',note:''})`);
 ev(`DB.returns.push({id:'drr1',num:9,date:'${D}T13:00:00.000Z',invoiceId:'di1',invoiceNum:4001,customerId:'',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:1,price:50,cost:40}],total:50,refundMethod:'كاش',note:''})`);
 const flBase=ev('floatBalance()');
 ev(`DB.serviceTxns.push({id:'ds1',date:'${D}T14:00:00.000Z',kind:'إرسال',service:'فودافون كاش',amount:1000,fee:10,customerName:'',note:''})`);
 ev(`DB.serviceTxns.push({id:'ds2',date:'${D}T15:00:00.000Z',kind:'استقبال',service:'فودافون كاش',amount:500,fee:15,customerName:'',note:''})`);
 ev(`DB.drawer.push({id:'dm1',date:'${D}T16:00:00.000Z',kind:'in',label:'إيداع صاحب المحل',amount:200,note:''})`);
 ev(`DB.drawer.push({id:'dm2',date:'${D}T17:00:00.000Z',kind:'out',label:'سحب صاحب المحل',amount:100,note:''})`);
 const dc3=ev(`dayCloseCalc('${DZ}')`);
 t('dayClose invCash split',dc3.invCash===100,'invCash='+dc3.invCash);
 t('dayClose payCash split',dc3.payCash===50,'payCash='+dc3.payCash);
 const dr=ev(`drawerCalc('${DZ}')`);
 t('drawer opening from last close actual',dr.opening===990,'opening='+dr.opening);
 t('drawer service cash in (amount+fee)',dr.svcIn===1010,'svcIn='+dr.svcIn);
 t('drawer service cash out (amount-fee)',dr.svcOut===485,'svcOut='+dr.svcOut);
 t('drawer expected math',dr.expected===1685,'expected='+dr.expected);
 ev(`DB.dayCloses.push({id:'dc1',day:'${D}',closedAt:'${D}T22:00:00.000Z',opening:990,expected:1685,actual:1680,diff:-5,payload:{},note:''})`);
 t('drawer closedToday visible',ev(`drawerCalc('${DZ}').closedToday.actual`)===1680);
 t('next day opening = today actual',ev(`drawerCalc('2020-02-21T00:00:00.000Z').opening`)===1680);
 t('float balance simple',ev('floatBalance()')===flBase-500,'float='+ev('floatBalance()')+' base='+flBase);
 ev(`DB.serviceTxns.push({id:'ds3',date:'${D}T18:00:00.000Z',kind:'تسوية',service:'',amount:1500,fee:0,customerName:'',note:'تسوية رصيد الفلوت'})`);
 t('float adjust via تسوية',ev('floatBalance()')===flBase+1000,'float='+ev('floatBalance()'));
 t('تسوية does not hit drawer',ev(`drawerCalc('${DZ}').expected`)===1685);
 /* service sheet e2e */
 ev('openServiceSheet()');
 ev(`$('#sv-amt').value='100';$('#sv-fee').value='5';$('#sv-cust').value='رضا';$('#sv-phone').value='01012345678'`);
 const svcN=ev('DB.serviceTxns.length');
 ev('saveService()');
 t('saveService appends txn',ev('DB.serviceTxns.length')===svcN+1);
 const lastSvc=ev('DB.serviceTxns[DB.serviceTxns.length-1]');
 t('saveService fields',lastSvc.kind==='إرسال'&&lastSvc.amount===100&&lastSvc.fee===5&&lastSvc.service==='فودافون كاش');
 t('saveService name/phone split',lastSvc.customerName==='رضا'&&lastSvc.customerPhone==='01012345678');
 ev('openServiceSheet()');
 t('service sheet has separate name+phone fields',ev(`!!document.getElementById('sv-cust')&&!!document.getElementById('sv-phone')`)===true);
 /* conditional fields */
 t('default service hides conditional fields',ev(`document.getElementById('sv-net-wrap').style.display==='none'&&document.getElementById('sv-util-wrap').style.display==='none'&&document.getElementById('sv-note-wrap').style.display==='none'`));
 ev(`segPick(document.querySelector('#sv-service button[data-v="كارت شحن"]'));svcServiceUI()`);
 t('كارت شحن shows network picker only',ev(`document.getElementById('sv-net-wrap').style.display==='block'&&document.getElementById('sv-util-wrap').style.display==='none'&&document.getElementById('sv-note-wrap').style.display==='none'`));
 ev(`segPick(document.querySelector('#sv-service button[data-v="كارت كهرباء"]'));svcServiceUI()`);
 t('كارت كهرباء shows utility picker only',ev(`document.getElementById('sv-util-wrap').style.display==='block'&&document.getElementById('sv-net-wrap').style.display==='none'&&document.getElementById('sv-note-wrap').style.display==='none'`));
 ev(`segPick(document.querySelector('#sv-service button[data-v="أخرى"]'));svcServiceUI()`);
 t('أخرى shows بيان field only',ev(`document.getElementById('sv-note-wrap').style.display==='block'&&document.getElementById('sv-net-wrap').style.display==='none'&&document.getElementById('sv-util-wrap').style.display==='none'`));
 /* كارت شحن with network */
 ev(`segPick(document.querySelector('#sv-service button[data-v="كارت شحن"]'));svcServiceUI();segPick(document.querySelector('#sv-net button[data-v="اتصالات"]'))`);
 ev(`$('#sv-amt').value='50';$('#sv-fee').value='2'`);
 ev('saveService()');
 const cardSvc=ev('DB.serviceTxns[DB.serviceTxns.length-1]');
 t('saveService stores network for كارت شحن',cardSvc.service==='كارت شحن'&&cardSvc.network==='اتصالات'&&cardSvc.amount===50);
 t('row shows network',ev(`vServices()`).includes('كارت شحن اتصالات'));
 ev(`DB.serviceTxns=DB.serviceTxns.filter(x=>x.id!=='${cardSvc.id}')`);
 /* كارت كهرباء with utility */
 ev('openServiceSheet()');
 ev(`segPick(document.querySelector('#sv-service button[data-v="كارت كهرباء"]'));svcServiceUI();segPick(document.querySelector('#sv-util button[data-v="مياه"]'))`);
 ev(`$('#sv-amt').value='100';$('#sv-fee').value='3'`);
 ev('saveService()');
 const utilSvc=ev('DB.serviceTxns[DB.serviceTxns.length-1]');
 t('saveService stores utility for كارت كهرباء',utilSvc.service==='كارت كهرباء'&&utilSvc.network==='مياه');
 t('row shows non-default utility',ev(`vServices()`).includes('كارت كهرباء مياه'));
 ev(`DB.serviceTxns=DB.serviceTxns.filter(x=>x.id!=='${utilSvc.id}')`);
 /* أخرى with note */
 ev('openServiceSheet()');
 ev(`segPick(document.querySelector('#sv-service button[data-v="أخرى"]'));svcServiceUI()`);
 ev(`$('#sv-amt').value='200';$('#sv-fee').value='5';$('#sv-note').value='دفع فاتورة كهربا'`);
 ev('saveService()');
 const otherSvc=ev('DB.serviceTxns[DB.serviceTxns.length-1]');
 t('saveService stores بيان for أخرى',otherSvc.service==='أخرى'&&otherSvc.note==='دفع فاتورة كهربا'&&otherSvc.network==='');
 ev(`DB.serviceTxns=DB.serviceTxns.filter(x=>x.id!=='${otherSvc.id}')`);
 ev('closeSheet()');
 /* فاتورة أرضي + فاتورة نت */
 t('bill types in service kinds',ev('SVC_KINDS').includes('فاتورة أرضي')&&ev('SVC_KINDS').includes('فاتورة نت'));
 ev('openServiceSheet()');
 ev(`segPick(document.querySelector('#sv-service button[data-v="فاتورة أرضي"]'));svcServiceUI()`);
 t('أرضي shows company picker',ev(`document.getElementById('sv-net-wrap').style.display==='block'&&document.getElementById('sv-net-lbl').textContent==='الشركة'`));
 t('أرضي provider is المصرية للاتصالات',ev(`document.querySelectorAll('#sv-net button').length===1&&document.querySelector('#sv-net button').dataset.v==='المصرية للاتصالات'`));
 ev(`$('#sv-amt').value='150';$('#sv-fee').value='5'`);
 ev('saveService()');
 const landSvc=ev('DB.serviceTxns[DB.serviceTxns.length-1]');
 t('saveService stores أرضي provider',landSvc.service==='فاتورة أرضي'&&landSvc.network==='المصرية للاتصالات');
 t('row shows أرضي provider',ev('vServices()').includes('فاتورة أرضي المصرية للاتصالات'));
 ev(`DB.serviceTxns=DB.serviceTxns.filter(x=>x.id!=='${landSvc.id}')`);
 ev('openServiceSheet()');
 ev(`segPick(document.querySelector('#sv-service button[data-v="فاتورة نت"]'));svcServiceUI()`);
 t('نت shows 4 providers',ev(`document.querySelectorAll('#sv-net button').length===4&&document.getElementById('sv-net-wrap').style.display==='block'`));
 ev(`segPick(document.querySelector('#sv-net button[data-v="وي"]'))`);
 ev(`$('#sv-amt').value='300';$('#sv-fee').value='6'`);
 ev('saveService()');
 const netSvc=ev('DB.serviceTxns[DB.serviceTxns.length-1]');
 t('saveService stores نت provider',netSvc.service==='فاتورة نت'&&netSvc.network==='وي');
 ev(`DB.serviceTxns=DB.serviceTxns.filter(x=>x.id!=='${netSvc.id}')`);
 ev('closeSheet()');
 /* seg wraps on narrow screens */
 t('seg chips wrap not clip',html.includes('.seg{display:flex;flex-wrap:wrap'));
 t('seg buttons can shrink',html.includes('.seg button{flex:1 1 auto;min-width:0'));
 t('كارت كهرباء in service kinds',ev('SVC_KINDS').includes('كارت كهرباء'));
 ev(`DB.serviceTxns=DB.serviceTxns.filter(x=>x.id!=='${lastSvc.id}')`);
 t('svcHint send text',(()=>{ev(`openServiceSheet();$('#sv-amt').value='100';$('#sv-fee').value='5';svcHint()`);const ok=ev(`$('#sv-hint').textContent.includes(fmt(105))&&$('#sv-hint').textContent.includes('الدرج')`);ev('closeSheet()');return ok;})());
 /* drawer entry sheet e2e */
 ev('openDrawerEntrySheet()');
 ev(`$('#dr-amt').value='75'`);
 const drN=ev('DB.drawer.length');
 ev('saveDrawerEntry()');
 t('saveDrawerEntry appends manual entry',ev('DB.drawer.length')===drN+1);
 const lastDr=ev('DB.drawer[DB.drawer.length-1]');
 t('drawer entry defaults owner-withdrawal',lastDr.kind==='out'&&lastDr.label==='سحب صاحب المحل'&&lastDr.amount===75);
 ev(`DB.drawer=DB.drawer.filter(x=>x.id!=='${lastDr.id}')`);
 /* close day record shape */
 ev(`openCloseDaySheet();$('#cd-actual').value='1680';$('#cd-note').value=''`);
 const clN=ev('DB.dayCloses.length');
 ev('doCloseDay()');
 t('doCloseDay appends close',ev('DB.dayCloses.length')===clN+1);
 const lastCl=ev('DB.dayCloses[DB.dayCloses.length-1]');
 t('close diff = actual - expected',lastCl.diff===Math.round((lastCl.actual-lastCl.expected)*100)/100);
 t('close payload snapshot',typeof lastCl.payload.sales==='number'&&typeof lastCl.payload.net==='number');
 ev(`DB.dayCloses=DB.dayCloses.filter(x=>x.id!=='${lastCl.id}')`);
 /* views render */
 t('vDrawer renders',ev('vDrawer()').includes('المفروض يكون في الدرج'));
 t('vServices renders',ev('vServices()').includes('عمولات النهارده'));
 t('dash has drawer+services buttons',ev('vDash()').includes("#/drawer")&&ev('vDash()').includes("#/services"));

 /* ---- stats dashboard ---- */
 t('dash has stats button',ev('vDash()').includes("#/stats"));
 const wk=ev(`statsRange('week')`);
 t('statsRange week starts Saturday',wk.f.getDay()===6&&wk.f.getHours()===0);
 const lm=ev(`statsRange('lastmonth')`);const nowD=new Date();
 t('statsRange lastmonth full prev month',lm.f.getDate()===1&&lm.f.getMonth()===(nowD.getMonth()+11)%12&&lm.t.getDate()===new Date(nowD.getFullYear(),nowD.getMonth(),0).getDate());
 const cr=ev(`statsRange('custom','2020-01-05','2020-01-20')`);
 t('statsRange custom honors from/to',cr.f.getDate()===5&&cr.t.getDate()===20&&cr.t.getHours()===23);
 /* seed a controlled stats window */
 ev(`DB.customers.push({id:'sc1',name:'زبون الاحصائيات',phone:'',type:'r'});DB.suppliers.push({id:'ss1',name:'مورد الاحصائيات',phone:''})`);
 ev(`DB.invoices.push({id:'st1',num:5001,date:'2020-03-10T10:00:00.000Z',customerId:'sc1',priceType:'w',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:4,price:50,cost:40},{productId:'p2',name:'أرز',unit:'كيلو',qty:2,price:60,cost:50}],total:320,paid:320,creditUsed:0,payMethod:'كاش'})`);
 ev(`DB.invoices.push({id:'st2',num:5002,date:'2020-03-12T10:00:00.000Z',customerId:'sc1',priceType:'w',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:1,price:50,cost:40}],total:50,paid:50,creditUsed:0,payMethod:'كاش'})`);
 ev(`DB.invoices.push({id:'st3',num:5003,date:'2020-03-12T11:00:00.000Z',customerId:'',priceType:'w',items:[{productId:'p3',name:'زيت',unit:'زجاجة',qty:1,price:100,cost:100}],total:100,paid:100,creditUsed:0,payMethod:'كاش'})`);
 ev(`DB.purchases.push({id:'stp1',date:'2020-03-11T10:00:00.000Z',supplierId:'ss1',items:[],total:900,paid:900})`);
 ev(`DB.purchases.push({id:'stp2',date:'2020-03-15T10:00:00.000Z',supplierId:'ss1',items:[],total:100,paid:100})`);
 ev(`DB.serviceTxns.push({id:'sts1',date:'2020-03-10T12:00:00.000Z',kind:'إرسال',service:'فودافون كاش',network:'',amount:500,fee:7,customerName:'',customerPhone:'',note:''})`);
 ev(`DB.expenses.push({id:'ste1',date:'2020-03-10T13:00:00.000Z',title:'نقل',amount:20,method:'كاش',note:''})`);
 ev(`DB.returns.push({id:'str1',num:10,date:'2020-03-12T12:00:00.000Z',invoiceId:'st1',invoiceNum:5001,customerId:'sc1',items:[{productId:'p1',name:'سكر',unit:'كيلو',qty:1,price:50,cost:40}],total:50,refundMethod:'كاش',note:''})`);
 ev(`DB.products.push({id:'szp1',name:'صنف راكد للاحصائيات',cat:'',unit:'قطعة',rPrice:1,wPrice:1,cost:1,stock:3,lowAt:0})`);
 const sc=ev(`statsCalc('custom','2020-03-01','2020-03-31')`);
 t('stats sales = sum invoices',sc.sales===470,'sales='+sc.sales);
 t('stats count+avg',sc.count===3&&Math.round(sc.avg)===157,'count='+sc.count+' avg='+sc.avg);
 t('stats profit items minus returns',sc.profit===60,'profit='+sc.profit);
 t('stats fees+expenses+net',sc.fees===7&&sc.expenses===20&&sc.net===47,'fees='+sc.fees+' net='+sc.net);
 t('stats top customer',sc.topCust&&sc.topCust.name==='زبون الاحصائيات'&&sc.topCust.count===2&&sc.topCust.total===370,'topCust='+JSON.stringify(sc.topCust));
 t('stats top supplier',sc.topSupp&&sc.topSupp.name==='مورد الاحصائيات'&&sc.topSupp.count===2&&sc.topSupp.total===1000,'topSupp='+JSON.stringify(sc.topSupp));
 t('stats top seller by qty',sc.sellers[0].name==='سكر'&&sc.sellers[0].qty===4,'s0='+JSON.stringify(sc.sellers[0]));
 t('stats returns cut qty',sc.sellers.find(x=>x.name==='سكر').qty===4,'سكر qty after return='+JSON.stringify(sc.sellers.map(x=>[x.name,x.qty])));
 t('stats slow movers flagged',sc.slow.length===3&&sc.slow.every(x=>x.badge==='راكد'||x.badge==='بطيء')&&sc.slow[0].sold===0,'slow='+JSON.stringify(sc.slow));
 t('vStats renders',ev('vStats()').includes('مبيعات الفترة')&&ev('vStats()').includes('أقل الأصناف حركة'));
 t('vStats custom shows date inputs',ev(`state.sp='custom';vStats()`).includes('type="date"'));

 /* ---- stage: barcode field on products ---- */
 t('ENT products barcode roundtrip',(r=>r&&r.barcode==='6223001234567')(ev(`ENT.products.unmap(ENT.products.map({id:'bp1',name:'زيت',cat:'',unit:'قطعة',rPrice:1,wPrice:1,cost:1,stock:1,lowAt:0,barcode:'6223001234567'}))`)));
 t('products unmap defaults empty barcode',ev(`ENT.products.unmap({id:'bp2',name:'x',cat:'',unit:'قطعة',price:1,wprice:1,cost:1,stock:1,lowat:0})`).barcode==='');
 ev(`DB.products.push({id:'bp3',name:'صنف باركود',cat:'',unit:'قطعة',rPrice:5,wPrice:4,cost:3,stock:2,lowAt:0,barcode:'6223001234567'})`);
 t('prodByBarcode finds product',ev(`prodByBarcode('6223001234567').id`)==='bp3');
 t('prodByBarcode trims input',ev(`prodByBarcode(' 6223001234567 ').id`)==='bp3');
 t('prodByBarcode misses unknown',ev(`typeof prodByBarcode('999')`)==='undefined');
 ev(`openProductSheet('bp3')`);
 t('product sheet shows barcode field',ev(`document.getElementById('fp-barcode').value`)==='6223001234567');
 ev(`document.getElementById('fp-barcode').value='111222333';saveProduct('bp3',false)`);
 await new Promise(r=>setTimeout(r,50));
 t('saveProduct stores barcode',ev(`DB.products.find(p=>p.id==='bp3').barcode`)==='111222333');
 ev(`closeSheet()`);

 /* ---- stage: barcode scanning ---- */
 t('pick sheet has camera button',ev(`vInvoice(null)`).length>0&&ev(`openPickProduct();document.querySelector('.overlay').innerHTML.includes('openScanSheet')`)===true);
 ev(`closeSheet()`);
 ev(`invDraft={customerId:'c1',priceType:'w',items:[],paid:'',disc:'',tax:'',useCredit:true,_preset:null}`);
 ev(`location.hash='#/invoice'`);
 ev(`scanCtx={mode:'invoice'}`);
 ev(`sheet('امسح باركود','<div id="scan-stage"></div>')`);
 ev(`scanResultCard('111222333')`);
 t('scan result card found',ev(`document.getElementById('scan-stage').innerHTML.includes('اتلاقى: صنف باركود')`)===true);
 const beforeItems=ev('invDraft.items.length');
 ev(`scanAddToInvoice('bp3')`);
 t('scan add to invoice',ev('invDraft.items.length')===beforeItems+1&&ev(`invDraft.items[invDraft.items.length-1].productId`)==='bp3');
 t('scan added card',ev(`document.getElementById('scan-stage').innerHTML.includes('اتضاف للفاتورة')`)===true);
 ev(`scanResultCard('0000000000000')`);
 t('scan result card not found',ev(`document.getElementById('scan-stage').innerHTML.includes('مش متسجل')`)===true);
 ev(`scanNewProduct()`);
 t('scan new product prefills barcode',ev(`document.getElementById('fp-barcode').value`)==='0000000000000');
 ev(`closeSheet()`);
 /* wedge: fast digits + enter outside fields */
 ev(`lastScanCode='';wedgeBuf=''`);
 for(const ch of '111222333'){ev(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'${ch}',bubbles:true}))`);}
 ev(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))`);
 t('wedge adds to invoice (bumps qty)',ev('invDraft.items.length')===beforeItems+1&&ev(`invDraft.items.find(x=>x.productId==='bp3').qty`)===2);
 /* wedge slow typing must not trigger */
 ev(`invDraft.items=[];wedgeBuf=''`);
 ev(`wedgeAt=Date.now()-500;document.dispatchEvent(new KeyboardEvent('keydown',{key:'1',bubbles:true}))`);
 ev(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))`);
 t('wedge ignores slow single key',ev('invDraft.items.length')===0);
 ev(`closeSheet();invDraft=null;location.hash='#/'`);
 t('scan link list renders',ev(`scanLinkListHTML('').includes('صنف باركود')`)===true);
 t('offerScanLink opens sheet',ev(`offerScanLink('777');document.querySelector('.overlay').innerHTML.includes('سجّله كصنف جديد')`)===true);
 ev(`assignBarcode('szp1')`);
 t('assignBarcode stores',ev(`DB.products.find(p=>p.id==='szp1').barcode`)==='777');
 ev(`closeSheet()`);

 /* ---- stage: label printing ---- */
 ev(`window.JsBarcode=function(el,code,opts){el.setAttribute('data-rendered',code)};window.__printed=0;window.print=()=>{window.__printed++}`);
 const vlb=ev('vLabels()');
 t('vLabels renders with barcode badge',vlb.includes('اطبع باركود')&&vlb.includes('صنف باركود'));
 t('vLabels flags product without barcode',ev('vLabels()').includes('مفيش باركود متسجل'));
 ev(`lblToggle('bp3')`);
 t('lblToggle selects 1',ev('labelDraft.bp3')===1);
 ev(`lblBump('bp3',2)`);
 t('lblBump adds',ev('labelDraft.bp3')===3);
 ev(`lblBump('bp3',-5)`);
 t('lblBump floors at 0',ev('labelDraft.bp3')===0);
 ev(`lblBump('bp3',4)`);
 await ev(`printLabels()`);
 await new Promise(r=>setTimeout(r,150));
 t('printLabels builds 4 labels',ev(`document.querySelectorAll('#print-area .pl-bc').length`)===4);
 t('printLabels renders barcodes',ev(`document.querySelectorAll('#print-area .pl-bc[data-rendered]').length`)===4);
 t('printLabels prints',ev('window.__printed')===1);
 t('labels small size default',ev(`document.getElementById('print-area').innerHTML.includes('50mm')`)===true);
 ev(`state.lblSize='m'`);
 await ev(`printLabels()`);
 t('labels medium size',ev(`document.getElementById('print-area').innerHTML.includes('70mm')`)===true);
 t('label preview html',ev(`labelPreviewHTML(DB.products.find(p=>p.id==='bp3'))`).includes('pl-bc'));
 ev(`window.__rc=0;render=(function(_r){return function(t){window.__rc++;return _r(t);};})(render)`);
 ev(`location.hash='#/labels'`);
 await new Promise(r=>setTimeout(r,150));
 ev(`window.__rc=0;vLabels()`);
 await new Promise(r=>setTimeout(r,150));
 t('vLabels no self-render loop when lib present',ev('window.__rc')===0);
 ev(`location.hash='#/'`);

 /* ---- photo bugfix: crop sheet must not kill product sheet ---- */
 ev(`openProductSheet('bp3')`);
 t('product sheet open',ev(`document.querySelectorAll('.overlay').length`)===1&&!!ev(`document.getElementById('fp-name')`));
 ev(`sheet('ظبط الصورة في المربع','<div></div>')`);
 t('crop sheet stacked',ev(`document.querySelectorAll('.overlay').length`)===2);
 ev(`crCancel()`);
 t('crCancel keeps product sheet',ev(`document.querySelectorAll('.overlay').length`)===1&&!!ev(`document.getElementById('fp-name')`));
 t('crDone uses closeTopSheet',ev('crDone.toString()').includes('closeTopSheet'));
 ev(`closeSheet()`);
 t('unmap photo from server photo_url',ev(`ENT.products.unmap({id:'px1',name:'x',cat:'',unit:'قطعة',price:1,wprice:1,cost:1,stock:1,lowat:0,barcode:'',photo_url:'https://x/y.jpg?v=3',updated_at:'2026-01-01'}).photo`)===1);
 t('unmap keeps local photo flag',ev(`ENT.products.unmap({id:'px1',name:'x',cat:'',unit:'قطعة',price:1,wprice:1,cost:1,stock:1,lowat:0,barcode:'',photo_url:null,updated_at:'2026-01-01'},{photo:1,photoVer:5}).photo`)===1);
 /* hydratePhotos falls back to storage URL when local blob missing */
 await ev(`(async()=>{const p=DB.products.find(x=>x.id==='bp3');p.photo=1;p.photoVer=9;await PHOTOS.del('bp3');delete photoURLs['bp3'];
  window.__oldFetch=window.fetch;window.fetch=async(u)=>({ok:true,blob:async()=>new Blob(['img'],{type:'image/jpeg'})});
  document.body.insertAdjacentHTML('beforeend','<img id="hyd-t" data-pid="bp3">');
  await hydratePhotos();
  window.fetch=window.__oldFetch;})()`);
 t('hydratePhotos fetches from storage',ev(`document.getElementById('hyd-t').src`)==='blob:mock');
 t('hydratePhotos cached blob locally',ev(`PHOTOS.get('bp3')`)!==null);


/* ---- round 33: photo version propagation ---- */
 t('unmap reads photoVer from server URL',ev(`ENT.products.unmap({id:'pv1',name:'x',cat:'',unit:'قطعة',price:5,wprice:4,cost:3,stock:1,lowat:0,barcode:'',photo_url:'https://x.co/product-photos/pv1.jpg?v=177',updated_at:'2026-01-01'},null).photoVer`)===177);
 ev(`localStorage.setItem('mahal_photo_up', JSON.stringify({pv2:5}))`);
 t('unmap clears photo when server null and upload done',ev(`ENT.products.unmap({id:'pv2',name:'x',cat:'',unit:'قطعة',price:5,wprice:4,cost:3,stock:1,lowat:0,barcode:'',photo_url:null,updated_at:'2026-01-01'},{id:'pv2',photo:1,photoVer:5}).photo`)===0);
 ev(`localStorage.setItem('mahal_photo_up', '{}')`);
 t('unmap keeps pending local photo when server null',ev(`ENT.products.unmap({id:'pv3',name:'x',cat:'',unit:'قطعة',price:5,wprice:4,cost:3,stock:1,lowat:0,barcode:'',photo_url:null,updated_at:'2026-01-01'},{id:'pv3',photo:1,photoVer:9}).photoVer`)===9);
 /* hydratePhotos refetches when server version newer, uses cache when same */
 await ev(`(async()=>{DB.products.push({id:'pv4',name:'قديم',cat:'',unit:'قطعة',rPrice:5,wPrice:4,cost:3,stock:1,lowAt:0,photo:1,photoVer:2});
  await PHOTOS.del('pv4');delete photoURLs['pv4'];
  localStorage.setItem('mahal_photo_dn', JSON.stringify({pv4:1}));
  window.__oldFetch=window.fetch;window.__fcount=0;
  window.fetch=async(u)=>{window.__fcount++;return {ok:true,blob:async()=>new Blob(['img'],{type:'image/jpeg'})}};
  document.body.insertAdjacentHTML('beforeend','<img id="pv4a" data-pid="pv4">');
  await hydratePhotos();})()`);
 t('refetch on newer server version',ev('window.__fcount')===1);
 t('img set after refetch',ev(`document.getElementById('pv4a').src`)==='blob:mock');
 t('dn marker updated',ev(`JSON.parse(localStorage.getItem('mahal_photo_dn')).pv4`)===2);
 await ev(`(async()=>{window.__fcount=0;
  window.fetch=async(u)=>{window.__fcount++;return {ok:false,status:404}};
  document.body.insertAdjacentHTML('beforeend','<img id="pv4b" data-pid="pv4">');
  await hydratePhotos();
  window.fetch=window.__oldFetch;})()`);
 t('no refetch when version same',ev('window.__fcount')===0);
 t('cached blob used',ev(`document.getElementById('pv4b').src`)==='blob:mock');


 /* Tenant switch isolation. Unit fixtures above intentionally use legacy keys. */
 ev(`activateTenant({tenantId:'tenant-unit-a'});curUser={owner:true,tenantId:'tenant-unit-a'};DB.products.push({id:'only-a',name:'A'});localStorage.setItem(KEY,JSON.stringify(DB));outboxSet([{qid:'a',rowId:'only-a'}]);sync2Set({products:'2026'});`);
 ev(`activateTenant({tenantId:'tenant-unit-b'});curUser={owner:true,tenantId:'tenant-unit-b'};`);
 t('new tenant has empty products',ev('DB.products.length')===0);
 t('new tenant has empty invoices',ev('DB.invoices.length')===0);
 t('new tenant has no prior outbox',ev('outboxGet().length')===0);
 t('new tenant has fresh cursor',ev('Object.keys(sync2Get()).length')===0);
 t('new tenant does not seed demo customers',ev('DB.customers.length')===0);
 t('new tenant skips legacy migration upload',ev('DB.settings.migratedV2')===true);
 ev(`activateTenant({tenantId:'tenant-unit-a'});curUser={owner:true,tenantId:'tenant-unit-a'};`);
 t('switch back restores only own products',ev('DB.products.length')===1&&ev('DB.products[0].id')==='only-a');
 t('switch back restores own queue',ev('outboxGet()[0].qid')==='a');
 t('photo versions are tenant-scoped',ev("tenantKey('mahal_photo_dn')")==='mahal_photo_dn_tenant-unit-a');
 t('blocked tenant render hides data',ev(`curUser.tenantBlocked=true;render();document.getElementById('app').innerText||document.getElementById('app').textContent`).includes('الاشتراك موقوف'));
 t('blocked tenant cannot flush',ev('flushOutbox.toString()').includes('curUser.tenantBlocked'));

 console.log('\n'+PASS+' passed, '+FAIL+' failed');
 if(FAIL){console.log('failures:',failures);process.exit(1);}
 process.exit(0);
})().catch(e=>{console.error('HARNESS ERROR',e);process.exit(2);});
