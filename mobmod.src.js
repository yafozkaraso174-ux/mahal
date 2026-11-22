/* ===== وحدة محل الموبايلات (بتشتغل بس لو نوع المحل = mobile) ===== */
const MOB_ENT=['devices','contracts','tickets'];
function isMobile(){return !!(curUser&&curUser.shopType==='mobile');}
function entOrder(){return isMobile()?ENT_ORDER.concat(MOB_ENT):ENT_ORDER;}
function mobEnsure(){if(!isMobile())return;MOB_ENT.forEach(k=>{if(!Array.isArray(DB[k]))DB[k]=[];});}
const _nowIso=()=>new Date().toISOString();
const mobJ=(tbl,extra)=>({table:tbl,ts:'updated_at',perms:['invoice','products'],
 map:x=>Object.assign({id:x.id,data:x,deleted:!!x.deleted,updated_at:_nowIso()},extra?extra(x):{}),
 unmap:r=>Object.assign({},r.data||{},{id:r.id,deleted:!!r.deleted})});
ENT.devices=mobJ('devices',x=>({imei:x.imei||''}));
ENT.contracts=mobJ('installment_contracts');
ENT.tickets=mobJ('repair_tickets');
function mobSave(kind,obj){const i=DB[kind].findIndex(x=>x.id===obj.id);if(i<0)DB[kind].push(obj);else DB[kind][i]=obj;save();
 enqueue({type:'upsert',table:ENT[kind].table,rowId:obj.id,row:ENT[kind].map(obj)});}
function mobNavbar(active){const it=(n,l,r,k)=>`<button class="nav-it${k===active?' on':''}" onclick="go('${r}')"><div class="ic">${ic(n)}</div><div class="tx">${l}</div></button>`;
return `<div class="navbar">${it('home','الرئيسية','#/','home')}${can('products')?it('box','الأجهزة','#/devices','dev'):''}${can('invoice')?`<div class="fab-wrap"><button class="fab" onclick="go('#/msale')">${ic('plus',26)}</button><div class="tx">بيع جهاز</div></div>`:''}${can('invoice')?it('cash','التقسيط','#/inst','inst'):''}${can('invoice')?it('gear','الصيانة','#/repairs','rep'):''}</div>`;}
/* ---------- helpers ---------- */
const MB_COND={new:'جديد',used:'مستعمل'};
function luhnOk(s){let sum=0;for(let i=0;i<15;i++){let d=+s[14-i];if(i%2===1){d*=2;if(d>9)d-=9;}sum+=d;}return sum%10===0;}
function imeiFmt(s){s=String(s||'');return s.length===15?`${s.slice(0,2)} ${s.slice(2,8)} ${s.slice(8,14)} ${s.slice(14)}`:s;}
function devName(d){return [d.brand,d.model,d.storage].filter(Boolean).join(' ')+(d.color?' · '+d.color:'');}
function devProdName(d){return [d.brand,d.model,d.storage].filter(Boolean).join(' ')+(d.cond==='used'?' (مستعمل)':'');}
function addMonthsISO(iso,m){const d=new Date(iso);const day=d.getDate();d.setMonth(d.getMonth()+m);if(d.getDate()!==day)d.setDate(0);return d.toISOString();}
function dueDateOf(fromIso,n,payDay){const f=new Date(fromIso);const y=f.getFullYear(),m=f.getMonth()+n;const last=new Date(y,m+1,0).getDate();return new Date(y,m,Math.min(payDay,last),12).toISOString();}
function warrDays(d){if(!d.warrantyEnd)return null;return Math.ceil((new Date(d.warrantyEnd)-Date.now())/86400000);}
function warrBadge(d){if(d.status!=='sold')return '';const n=warrDays(d);if(!d.warrantyMonths)return '<span class="mbb mb-m">بدون ضمان</span>';return n>=0?`<span class="mbb mb-g">الضمان ساري · باقي ${fmt(n)} يوم</span>`:'<span class="mbb mb-r">الضمان منتهي</span>';}
function devBadge(d){return d.status==='sold'?'<span class="mbb mb-b">اتباع</span>':'<span class="mbb mb-g">في المحل</span>';}
function mobIsModel(p){return p.cat==='موبايلات'||DB.devices.some(d=>d.productId===p.id);}
function mobModelProduct(d){const nm=devProdName(d);let p=DB.products.find(x=>x.name===nm&&x.cat==='موبايلات');
 if(!p){p={id:uid(),name:nm,cat:'موبايلات',unit:'جهاز',wPrice:d.price,rPrice:d.price,cost:d.cost,stock:0,lowAt:0,barcode:''};DB.products.push(p);}return p;}
function devPhoneSvg(d){const c=d.cond==='used'?'#b58cff':'#4fb3ff';return `<svg viewBox="0 0 26 44" style="width:34px;height:56px"><rect x="2" y="1" width="22" height="42" rx="5" fill="#2b3a52"/><rect x="4" y="5" width="18" height="32" rx="2" fill="${c}"/></svg>`;}
function installCalc(o){const price=o.price,down=Math.min(Math.max(0,o.down),price);const rem=Math.round((price-down)*100)/100;
 let fee=o.feeMode==='total'?Math.max(0,Math.round((o.feeTotal-rem)*100)/100):Math.round(rem*o.feePct)/100;if(o.feeMode==='total'&&!(o.feeTotal>0))fee=0;
 const total=Math.round((rem+fee)*100)/100;const n=Math.max(1,o.months|0);const base=Math.floor(total/n*100)/100;
 const sched=[];let acc=0;for(let i=1;i<=n;i++){const a=i===n?Math.round((total-acc)*100)/100:base;acc+=a;sched.push({n:i,due:dueDateOf(o.from,i,o.payDay),amt:a,paidAmt:0,paidAt:null});}
 return {down,rem,fee,total,monthly:base,sched,invTotal:Math.round((price+fee)*100)/100};}
function instPaid(c){return c.schedule.reduce((s,x)=>s+x.paidAmt,0);}
function instLeft(c){return Math.round((c.total-instPaid(c))*100)/100;}
function instNext(c){return c.schedule.find(x=>x.paidAmt<x.amt-0.005);}
function instLate(c){const t=Date.now();return c.schedule.filter(x=>x.paidAmt<x.amt-0.005&&new Date(x.due)<t);}
/* ---------- لوحة الرئيسية ---------- */
function mobDashHTML(){const inStock=DB.devices.filter(d=>!d.deleted&&d.status==='in').length;const act=DB.contracts.filter(c=>!c.deleted&&instLeft(c)>0.005);
 const late=act.filter(c=>instLate(c).length).length;const wk=act.filter(c=>{const n=instNext(c);return n&&new Date(n.due)-Date.now()<7*86400000&&new Date(n.due)>=Date.now();}).length;
 const rOpen=DB.tickets.filter(t=>!t.deleted&&t.status!=='done').length,rReady=DB.tickets.filter(t=>!t.deleted&&t.status==='ready').length;
 const st=(l,v,s,c)=>`<div class="stat"><div class="lbl">${l}</div><div class="val"${c?` style="color:${c}"`:''}>${v}</div><div class="sub">${s}</div></div>`;
 return `<div class="sec-title">محل الموبايلات</div><div class="grid2">${st('أجهزة في المحل',fmt(inStock),'جهاز بـ IMEI')}${st('أقساط متأخرة',fmt(late),'عميل · وفي الأسبوع الجاي '+fmt(wk),late?'var(--red)':'')}${st('صيانة مفتوحة',fmt(rOpen),fmt(rReady)+' جاهزة للتسليم')}${st('عقود تقسيط شغالة',fmt(act.length),'متبقي '+fmt(act.reduce((s,c)=>s+instLeft(c),0))+' ج')}</div>
<div class="actions" style="margin-top:10px"><button class="act" onclick="go('#/msale')"><div class="ic" style="background:var(--green-soft);color:var(--green)">${ic('plus')}</div><div class="tx">بيع جهاز</div></button><button class="act" onclick="openDeviceSheet()"><div class="ic" style="background:var(--blue-soft);color:var(--blue)">${ic('down')}</div><div class="tx">استلام جهاز</div></button><button class="act" onclick="go('#/warranty')"><div class="ic" style="background:var(--amber-soft);color:#9A6A14">${ic('tag')}</div><div class="tx">الضمان بالـ IMEI</div></button><button class="act" onclick="openTicketSheet()"><div class="ic" style="background:var(--red-soft);color:var(--red)">${ic('gear')}</div><div class="tx">تذكرة صيانة</div></button></div>`;}
/* ---------- راوتر ---------- */
function mobRoute(h){if(!isMobile())return null;
 if(h==='#/devices')return can('products')?vDevices():vNoPerm();
 if(h==='#/msale')return can('invoice')?vMobSale():vNoPerm();
 if(h==='#/inst')return can('invoice')?vInst():vNoPerm();
 if(h==='#/repairs')return can('invoice')?vRepairs():vNoPerm();
 if(h==='#/warranty')return vWarranty();
 return null;}
function mobHead(title,sub,right){return `<div class="appbar"><div>${backBtn('#/')}<div class="shop" style="margin-top:4px">${title}</div>${sub?`<div class="hello">${sub}</div>`:''}</div>${right||''}</div>`;}
/* ---------- الأجهزة ---------- */
state.dq='';state.dst='all';
function devMatch(d){const q=(state.dq||'').trim().toLowerCase();if(d.deleted)return false;if(state.dst==='in'&&d.status!=='in')return false;if(state.dst==='sold'&&d.status!=='sold')return false;if(state.dst==='used'&&d.cond!=='used')return false;
 if(!q)return true;const c=cust(d.customerId);return (d.imei||'').includes(q)||devName(d).toLowerCase().includes(q)||(c&&c.name.toLowerCase().includes(q));}
function devCardHTML(d){const openT=DB.tickets.some(t=>!t.deleted&&t.deviceId===d.id&&t.status!=='done');const c=cust(d.customerId);
 return `<button class="pcard" onclick="openDeviceDetail('${d.id}')"><div class="art"><div class="ph">${devPhoneSvg(d)}</div><span class="unit">${MB_COND[d.cond]}</span>${d.cond==='used'&&d.battery?`<span class="stk">بطارية ${fmt(d.battery)}٪</span>`:''}</div><div class="info"><div class="nm" style="white-space:normal;overflow:visible;line-height:1.35">${esc(devName(d))}</div><div class="ds mbimei" style="font-size:11px;direction:ltr;text-align:right">${imeiFmt(d.imei)}</div><div class="mbbadges">${devBadge(d)} ${warrBadge(d)}${openT?' <span class="mbb mb-r">في الصيانة</span>':''}</div>${c?`<div class="ds" style="margin:4px 0 0">اتباع لـ ${esc(c.name)}</div>`:''}<div class="pr" style="margin-top:7px"><b>${fmt(d.price)} <small>ج</small></b></div></div></button>`;}
function vDevices(){const list=DB.devices.filter(devMatch).sort((a,b)=>(a.status===b.status?0:a.status==='in'?-1:1)||(b.createdAt||'').localeCompare(a.createdAt||''));
 const all=DB.devices.filter(d=>!d.deleted);const cnt=k=>all.filter(d=>k==='in'?d.status==='in':k==='sold'?d.status==='sold':k==='used'?d.cond==='used':true).length;
 const ch=(k,l)=>`<button class="chip${state.dst===k?' on':''}" onclick="state.dst='${k}';render()">${l} (${fmt(cnt(k))})</button>`;
 return mobHead('مخزن الأجهزة','كل جهاز بالـ IMEI بتاعه',`<div style="display:flex;gap:8px"><button class="avatar" style="background:var(--amber)" onclick="go('#/warranty')" title="الضمان">${ic('tag',22)}</button><button class="avatar" style="background:var(--green)" onclick="openDeviceSheet()" title="استلام جهاز">${ic('plus',22)}</button></div>`)+`<div class="content">
<div class="search">${ic('search',18)}<input placeholder="IMEI أو موديل أو اسم عميل…" value="${esc(state.dq)}" oninput="state.dq=this.value;$('#dlist').innerHTML=devListHTML()"></div>
<div class="chips">${ch('all','الكل')}${ch('in','في المحل')}${ch('sold','اتباع')}${ch('used','مستعمل')}</div><div id="dlist">${devListHTML()}</div></div>`+navbar('dev');}
function devListHTML(){const l=DB.devices.filter(devMatch).sort((a,b)=>(a.status===b.status?0:a.status==='in'?-1:1)||(b.createdAt||'').localeCompare(a.createdAt||''));return l.length?'<div class="pgrid">'+l.map(devCardHTML).join('')+'</div>':`<div class="empty"><div class="big">مفيش أجهزة هنا</div>اضغط ＋ عشان تستلم جهاز بالـ IMEI</div>`;}
function openDeviceSheet(id){const d=id?DB.devices.find(x=>x.id===id):null;const sups=DB.suppliers.filter(s=>!s.deleted);
 const f=(k,l,v,ph,ex)=>`<div class="field"><div class="lbl">${l}</div><input id="dv-${k}" value="${esc(v??'')}" placeholder="${ph||''}" ${ex||''}></div>`;
 sheet(d?'تعديل جهاز':'استلام جهاز',`<div class="g2m">${f('brand','الماركة',d?.brand,'Samsung')}${f('model','الموديل',d?.model,'Galaxy A55')}${f('storage','السعة',d?.storage,'256GB')}${f('color','اللون',d?.color,'أسود')}</div>
${f('imei','IMEI (١٥ رقم)',d?.imei,'35xxxxxxxxxxxxx','inputmode="numeric" maxlength="17" style="direction:ltr;text-align:left;font-family:monospace"')}
<div class="field"><div class="lbl">الحالة</div><div class="seg" id="dv-cond"><button class="${!d||d.cond==='new'?'on':''}" data-v="new" onclick="segPick(this);devCondUi()">جديد</button><button class="${d&&d.cond==='used'?'on':''}" data-v="used" onclick="segPick(this);devCondUi()">مستعمل</button></div></div>
<div id="dv-usedbox" style="display:${d&&d.cond==='used'?'block':'none'}"><div class="g2m">${f('battery','صحة البطارية ٪',d?.battery,'87','inputmode="numeric"')}${f('seller','اسم البايع',d?.sellerName,'اشتراه المحل من')}${f('sellerId','رقم بطاقة البايع',d?.sellerNid,'','inputmode="numeric"')}${f('sellerPhone','تليفون البايع',d?.sellerPhone,'','inputmode="tel"')}</div></div>
<div class="g2m">${f('cost','سعر الشراء',d?.cost,'','inputmode="decimal"')}${f('price','سعر البيع',d?.price,'','inputmode="decimal"')}${f('warr','الضمان (شهور)',d?d.warrantyMonths:12,'12','inputmode="numeric"')}</div>
<div class="field"><div class="lbl">المورد (اختياري)</div><select id="dv-sup"><option value="">—</option>${sups.map(s=>`<option value="${s.id}"${d&&d.supplierId===s.id?' selected':''}>${esc(s.name)}</option>`).join('')}</select></div>
<button class="btn btn-p" style="width:100%" onclick="saveDevice('${id||''}')">${d?'حفظ ✓':'استلام الجهاز ✓'}</button>`);}
function devCondUi(){const u=$('#dv-cond button.on')?.dataset.v==='used';$('#dv-usedbox').style.display=u?'block':'none';const w=$('#dv-warr');if(w&&!w.dataset.touched){w.value=u?3:12;}}
function saveDevice(id){const g=k=>($('#dv-'+k)?.value||'').trim();const imei=g('imei').replace(/\D/g,'');const cond=$('#dv-cond button.on')?.dataset.v||'new';
 if(!g('model')){toast('اكتب الموديل');return;}
 if(imei.length!==15){toast('الـ IMEI لازم ١٥ رقم');return;}
 if(DB.devices.some(x=>!x.deleted&&x.imei===imei&&x.id!==id)){toast('الـ IMEI ده متسجل قبل كده');return;}
 if(!luhnOk(imei)&&!confirm('الـ IMEI ده شكله غلط (فشل فحص الأرقام). تحفظه برضه؟'))return;
 const price=num(g('price')),cost=num(g('cost'));if(price<=0){toast('اكتب سعر البيع');return;}
 const old=id?DB.devices.find(x=>x.id===id):null;
 const d=Object.assign({},old||{id:uid(),status:'in',createdAt:_nowIso()},{brand:g('brand'),model:g('model'),storage:g('storage'),color:g('color'),imei,cond,battery:cond==='used'?num(g('battery')):0,sellerName:g('seller'),sellerNid:g('sellerId'),sellerPhone:g('sellerPhone'),cost,price,warrantyMonths:Math.max(0,Math.round(num(g('warr')))),supplierId:$('#dv-sup')?.value||''});
 const p=mobModelProduct(d);
 if(!old){const b=p.stock;p.stock=b+1;d.productId=p.id;logMove(p.id,'in',1,b,p.stock,'استلام جهاز '+imei,uid());enqueue({type:'upsert',table:'movements',rowId:DB.movements[DB.movements.length-1].id,prefer:'resolution=ignore-duplicates',row:ENT.movements.map(DB.movements[DB.movements.length-1])});}
 if(old&&old.status==='in'){p.rPrice=p.wPrice=price;p.cost=cost;}
 else if(!old){p.rPrice=p.wPrice=price;p.cost=cost;}
 enqueue({type:'upsert',table:'products',rowId:p.id,row:ENT.products.map(p)});
 mobSave('devices',d);closeSheet();render();toast(old?'اتحفظ ✓':'الجهاز اتضاف للمخزن ✓');}
function openDeviceDetail(id){const d=DB.devices.find(x=>x.id===id);if(!d)return;const c=cust(d.customerId);const inv=d.invoiceId?DB.invoices.find(i=>i.id===d.invoiceId):null;
 const r=(k,v)=>`<div class="trow"><span class="k">${k}</span><span style="font-weight:800">${v}</span></div>`;
 sheet(devName(d),`<div class="total-card">${r('IMEI',`<span class="mbimei">${imeiFmt(d.imei)}</span>`)}${r('الحالة',MB_COND[d.cond]+(d.cond==='used'&&d.battery?' · بطارية '+fmt(d.battery)+'٪':''))}${r('سعر الشراء / البيع',fmt(d.cost)+' / '+fmt(d.price)+' ج')}${r('الضمان',d.warrantyMonths?d.warrantyMonths+' شهر':'بدون')}
${d.status==='sold'?r('اتباع لـ',c?esc(c.name):'—')+r('تاريخ البيع',new Date(d.soldAt).toLocaleDateString(AR))+r('الضمان',warrBadge(d))+(inv?r('الفاتورة','#'+inv.num.toLocaleString(AR)):''):''}
${d.cond==='used'&&d.sellerName?r('اشتراه من',esc(d.sellerName)+(d.sellerNid?' · '+esc(d.sellerNid):'')):''}</div>
<div style="display:flex;gap:8px;margin-top:12px;flex-wrap:wrap">${d.status==='sold'?`<button class="btn btn-p" onclick="printWarranty('${d.id}')">طباعة شهادة الضمان</button><button class="btn" style="background:var(--green-soft);color:var(--green)" onclick="waWarranty('${d.id}')">واتساب الشهادة</button><button class="btn" style="background:var(--amber-soft);color:#9A6A14" onclick="closeSheet();openTicketSheet('','${d.id}')">فتح تذكرة صيانة</button>`:`<button class="btn btn-p" onclick="closeSheet();openDeviceSheet('${d.id}')">تعديل</button><button class="btn" style="background:var(--red-soft);color:var(--red)" onclick="delDevice('${d.id}')">مسح</button>`}</div>`);}
function delDevice(id){const d=DB.devices.find(x=>x.id===id);if(!d||d.status!=='in')return;if(!confirm('تمسح الجهاز ده من المخزن؟'))return;
 const p=prod(d.productId);if(p){const b=p.stock;p.stock=Math.max(0,b-1);logMove(p.id,'edit',-1,b,p.stock,'مسح جهاز',uid());enqueue({type:'upsert',table:'movements',rowId:DB.movements[DB.movements.length-1].id,prefer:'resolution=ignore-duplicates',row:ENT.movements.map(DB.movements[DB.movements.length-1])});enqueue({type:'upsert',table:'products',rowId:p.id,row:ENT.products.map(p)});}
 d.deleted=true;mobSave('devices',d);closeSheet();render();toast('اتمسح');}
/* ---------- شهادة الضمان ---------- */
function warrText(d){const c=cust(d.customerId);return `شهادة ضمان — ${DB.settings.shopName}\n${devName(d)}\nIMEI: ${d.imei}\nتاريخ البيع: ${new Date(d.soldAt).toLocaleDateString(AR)}\nالضمان: ${d.warrantyMonths} شهر — لحد ${new Date(d.warrantyEnd).toLocaleDateString(AR)}\n${c?'العميل: '+c.name:''}`;}
function printWarranty(id){const d=DB.devices.find(x=>x.id===id);if(!d||d.status!=='sold')return;const c=cust(d.customerId);
 $('#print-area').innerHTML=`<div class="p-head"><h1>${esc(DB.settings.shopName)}</h1><p>شهادة ضمان</p></div><div style="font-size:15px;line-height:2.1;padding:6mm"><b>الجهاز:</b> ${esc(devName(d))}<br><b>IMEI:</b> <span dir="ltr">${esc(d.imei)}</span><br><b>الحالة:</b> ${MB_COND[d.cond]}<br><b>العميل:</b> ${esc(c?.name||'')}<br><b>تاريخ البيع:</b> ${new Date(d.soldAt).toLocaleDateString(AR)}<br><b>مدة الضمان:</b> ${d.warrantyMonths} شهر — تنتهي ${new Date(d.warrantyEnd).toLocaleDateString(AR)}<br><small>الضمان لا يشمل الكسر وسوء الاستخدام والسوائل.</small></div>`;setTimeout(()=>window.print(),80);}
function waWarranty(id){const d=DB.devices.find(x=>x.id===id);const c=d&&cust(d.customerId);const u=waLink(c&&c.phone,warrText(d));if(!u){toast('مفيش رقم تليفون للعميل');return;}window.open(u,'_blank');}
/* ---------- بيع جهاز ---------- */
let mobCart=[],mobPay={mode:'cash',customerId:'',paid:'',months:12,down:'',feeMode:'pct',feePct:10,feeTotal:'',payDay:5,guarantor:'',gphone:''};state.mq='';state.mc='all';
function mobSaleItems(){const q=(state.mq||'').trim().toLowerCase();const ds=DB.devices.filter(d=>!d.deleted&&d.status==='in'&&(state.mc==='all'||state.mc===d.cond)&&(!q||d.imei.includes(q)||devName(d).toLowerCase().includes(q)));
 const ac=(state.mc==='all'||state.mc==='acc')?DB.products.filter(p=>!mobIsModel(p)&&!p.deleted&&p.stock>0&&(!q||p.name.toLowerCase().includes(q)||(p.barcode||'')===q)):[];
 return {ds:state.mc==='acc'?[]:ds,ac};}
function mobCardHTML(it){if(it.d){const d=it.d;const inC=mobCart.some(x=>x.k==='d'&&x.id===d.id);
 return `<button class="pcard${inC?' mbsel':''}" onclick="mobToggle('d','${d.id}')"><div class="art"><div class="ph">${devPhoneSvg(d)}</div><span class="unit">${MB_COND[d.cond]}</span>${d.warrantyMonths?`<span class="stk">ضمان ${d.warrantyMonths} شهر</span>`:''}</div><div class="info"><div class="nm">${esc(devName(d))}</div><div class="ds mbimei">…${esc(d.imei.slice(-8))}</div><div class="pr"><b>${fmt(d.price)} <small>ج</small></b><span class="plus">${inC?ic('check',18):ic('plus',18)}</span></div></div></button>`;}
 const p=it.p;const q=(mobCart.find(x=>x.k==='p'&&x.id===p.id)||{}).qty||0;
 return `<button class="pcard${q?' mbsel':''}" onclick="mobToggle('p','${p.id}')"><div class="art"><div class="ph">${ic('box',44)}</div><span class="unit">إكسسوار</span><span class="stk">${fmt(p.stock)} متاح</span></div><div class="info"><div class="nm">${esc(p.name)}</div><div class="ds">${q?'في الفاتورة × '+fmt(q):'بدون IMEI'}</div><div class="pr"><b>${fmt(p.rPrice)} <small>ج</small></b><span class="plus">${ic('plus',18)}</span></div></div></button>`;}
function mobSaleGrid(){const {ds,ac}=mobSaleItems();const items=ds.map(d=>({d})).concat(ac.map(p=>({p})));return items.length?`<div class="pgrid">${items.map(mobCardHTML).join('')}</div>`:`<div class="empty"><div class="big">مفيش حاجة تتباع</div>استلم أجهزة الأول من مخزن الأجهزة</div>`;}
function mobToggle(k,id){const i=mobCart.findIndex(x=>x.k===k&&x.id===id);if(k==='d'){if(i>=0)mobCart.splice(i,1);else mobCart.push({k,id});}
 else{const p=prod(id);if(i>=0){if(mobCart[i].qty+1>p.stock){toast('المتاح '+fmt(p.stock)+' بس');return;}mobCart[i].qty++;}else mobCart.push({k,id,qty:1});}
 $('#msg').innerHTML=mobSaleGrid();mobBar();}
function mobCartTotal(){return mobCart.reduce((s,x)=>{if(x.k==='d'){const d=DB.devices.find(z=>z.id===x.id);return s+(d?d.price:0);}const p=prod(x.id);return s+(p?p.rPrice*x.qty:0);},0);}
function mobBar(){const b=$('#mbbar');if(!b)return;const n=mobCart.reduce((s,x)=>s+(x.qty||1),0);b.style.display=n?'flex':'none';b.innerHTML=`<span>عرض الفاتورة · ${fmt(n)} ${n===1?'صنف':'أصناف'}</span><b>${fmt(mobCartTotal())} ج</b>`;}
function vMobSale(){const ch=(k,l)=>`<button class="chip${state.mc===k?' on':''}" onclick="state.mc='${k}';render()">${l}</button>`;
 return mobHead('بيع جهاز','اختار الأجهزة والإكسسوارات')+`<div class="content" style="padding-bottom:150px"><div class="search">${ic('search',18)}<input placeholder="دوّر بالموديل أو IMEI أو باركود…" value="${esc(state.mq)}" oninput="state.mq=this.value;$('#msg').innerHTML=mobSaleGrid()" onkeydown="if(event.key==='Enter')mobScanEnter(this)"></div>
<div class="chips">${ch('all','كل الأجهزة')}${ch('new','جديد')}${ch('used','مستعمل')}${ch('acc','إكسسوارات')}</div><div id="msg">${mobSaleGrid()}</div></div><button id="mbbar" class="mbbar" onclick="openMobCheckout()" style="display:none"></button>`+navbar('');}
function mobScanEnter(el){const c=el.value.trim();const d=DB.devices.find(x=>!x.deleted&&x.status==='in'&&x.imei===c);if(d){if(!mobCart.some(x=>x.k==='d'&&x.id===d.id))mobCart.push({k:'d',id:d.id});el.value='';state.mq='';$('#msg').innerHTML=mobSaleGrid();mobBar();}}
/* بعد كل رسم لصفحة البيع نظهر الشريط */
function mobAfterRender(){if(location.hash==='#/msale')mobBar();}
function mobPayVals(){const P=mobPay;const price=mobCartTotal();return {price,calc:P.mode==='inst'?installCalc({price,down:num(P.down),feeMode:P.feeMode,feePct:num(P.feePct),feeTotal:num(P.feeTotal),months:P.months,payDay:Math.min(28,Math.max(1,num(P.payDay)||5)),from:_nowIso()}):null};}
function openMobCheckout(){if(!mobCart.length)return;if(!mobPay.customerId&&DB.customers.length===1)mobPay.customerId=DB.customers[0].id;
 sheet('إتمام البيع','<div id="mc-body"></div>');mobCheckoutRender();}
function mobCheckoutRender(){const P=mobPay;const {price,calc}=mobPayVals();const hasDev=mobCart.some(x=>x.k==='d');
 const lines=mobCart.map((x,i)=>{if(x.k==='d'){const d=DB.devices.find(z=>z.id===x.id);return `<div class="trow"><span>${esc(devName(d))} <span class="mbimei">…${d.imei.slice(-6)}</span></span><span><b>${fmt(d.price)}</b> <button onclick="mobCart.splice(${i},1);mobCart.length?mobCheckoutRender():closeSheet();render()" style="color:var(--red)">✕</button></span></div>`;}const p=prod(x.id);return `<div class="trow"><span>${esc(p.name)} × ${fmt(x.qty)}</span><span><b>${fmt(p.rPrice*x.qty)}</b> <button onclick="mobCart.splice(${i},1);mobCart.length?mobCheckoutRender():closeSheet();render()" style="color:var(--red)">✕</button></span></div>`;}).join('');
 const segB=(k,v,l)=>`<button class="${P[k]===v?'on':''}" onclick="mobPay.${k}=${typeof v==='number'?v:`'${v}'`};mobCheckoutRender()">${l}</button>`;
 const inp=(k,l,ph,ex)=>`<div class="field"><div class="lbl">${l}</div><input value="${esc(P[k])}" placeholder="${ph||''}" ${ex||'inputmode="decimal"'} oninput="mobPay.${k}=this.value;mobCheckoutCalc()"></div>`;
 $('#mc-body').innerHTML=`<div class="field"><div class="lbl">العميل</div><div style="display:flex;gap:8px"><select style="flex:1" onchange="mobPay.customerId=this.value"><option value="">— اختار العميل —</option>${DB.customers.filter(c=>!c.deleted).map(c=>`<option value="${c.id}"${P.customerId===c.id?' selected':''}>${esc(c.name)}</option>`).join('')}</select><button class="cbtn" style="flex:none;padding:10px;background:var(--green-soft);color:var(--green)" onclick="mobNewCust()">＋</button></div></div>
<div class="total-card">${lines}</div>
<div class="field" style="margin-top:12px"><div class="lbl">طريقة الدفع</div><div class="seg">${segB('mode','cash','كاش')}${hasDev?segB('mode','inst','تقسيط'):''}</div></div>
${P.mode==='cash'?`<div class="field"><div class="lbl">المدفوع (سيبه فاضي = كامل المبلغ)</div><input inputmode="decimal" value="${esc(P.paid)}" oninput="mobPay.paid=this.value;mobCheckoutCalc()"></div>`:`<div class="total-card"><div class="lbl" style="font-weight:800;margin-bottom:6px">عدد الشهور</div><div class="seg">${[6,9,12,18,24].map(m=>segB('months',m,m+' ش')).join('')}</div>
<div class="g2m" style="margin-top:8px">${inp('down','المقدم')}${inp('payDay','يوم الدفع كل شهر','5','inputmode="numeric"')}</div>
<div class="lbl" style="font-weight:800;margin:6px 0">المصاريف / الفايدة</div><div class="seg">${segB('feeMode','pct','نسبة ٪ على المتبقي')}${segB('feeMode','total','إجمالي المتبقي أكتبه أنا')}</div>
${P.feeMode==='pct'?inp('feePct','النسبة ٪','10'):inp('feeTotal','إجمالي اللي هيتقسّط (بعد المقدم)','')}
<div class="g2m">${inp('guarantor','اسم الضامن','','')}${inp('gphone','تليفون الضامن','','inputmode="tel"')}</div></div>`}
<div class="total-card" id="mc-sum"></div><button class="btn btn-p" style="width:100%;margin-top:12px" onclick="saveMobSale()">إتمام البيع وطباعة الضمان ✓</button>`;mobCheckoutCalc();}
function mobCheckoutCalc(){const P=mobPay;const {price,calc}=mobPayVals();const r=(k,v,c)=>`<div class="trow"><span class="k">${k}</span><span style="font-weight:900${c?';color:'+c:''}">${v}</span></div>`;let h='';
 if(P.mode==='cash'){const paid=P.paid===''?price:Math.min(price,num(P.paid));h=r('الإجمالي',fmt(price)+' ج')+r('المدفوع',fmt(paid)+' ج')+(price-paid>0?r('باقي على العميل',fmt(price-paid)+' ج','var(--red)'):'');}
 else{h=r('سعر الأجهزة',fmt(price)+' ج')+r('المقدم',fmt(calc.down)+' ج')+r('المتبقي',fmt(calc.rem)+' ج')+r('المصاريف',fmt(calc.fee)+' ج')+r('إجمالي الفاتورة',fmt(calc.invTotal)+' ج')+r('القسط الشهري',fmt(calc.monthly)+' ج × '+P.months,'var(--green)');}
 const el=$('#mc-sum');if(el)el.innerHTML=h;}
function mobNewCust(){const n=prompt('اسم العميل');if(!n||!n.trim())return;const ph=prompt('رقم التليفون (للواتساب)')||'';const c={id:uid(),name:n.trim(),phone:ph.trim(),type:'r'};DB.customers.push(c);save();enqueue({type:'upsert',table:'customers',rowId:c.id,row:ENT.customers.map(c)});mobPay.customerId=c.id;mobCheckoutRender();}
function saveMobSale(){const P=mobPay;if(!P.customerId){toast('اختار العميل الأول');return;}if(!mobCart.length)return;
 const {price,calc}=mobPayVals();const now=_nowIso();const items=[];const devs=[];
 for(const x of mobCart){if(x.k==='d'){const d=DB.devices.find(z=>z.id===x.id);if(!d||d.status!=='in'){toast('جهاز اتباع قبل كده — شيله من الفاتورة');return;}const p=prod(d.productId);if(!p||p.stock<=0){toast('المخزون مش مظبوط للجهاز ده');return;}
  items.push({productId:d.productId,name:devName(d)+' · IMEI '+d.imei,unit:'جهاز',qty:1,price:d.price,cost:d.cost,imei:d.imei,deviceId:d.id,warrantyMonths:d.warrantyMonths,moveId:uid(),moveKind:'sale'});devs.push(d);}
  else{const p=prod(x.id);if(!p||x.qty>p.stock){toast('المتاح من "'+(p?p.name:'')+'" أقل');return;}items.push({productId:p.id,name:p.name,unit:p.unit,qty:x.qty,price:p.rPrice,cost:p.cost,moveId:uid(),moveKind:'sale'});}}
 let total=price,paid,fee=0;if(P.mode==='inst'){if(!(P.months>0)||calc.total<=0){toast('راجع بيانات التقسيط');return;}fee=calc.fee;total=calc.invTotal;paid=calc.down;}
 else paid=P.paid===''?price:Math.min(price,num(P.paid));
 const inv={id:uid(),num:DB.nextNum++,date:now,customerId:P.customerId,priceType:'r',items,discPct:0,taxPct:0,discAmt:0,taxAmt:fee,deliveryFee:0,total,paid,creditUsed:0,payMethod:'كاش',mobile:1};
 items.forEach(it=>{const p=prod(it.productId);if(p){const b=p.stock;p.stock=Math.round((p.stock-it.qty)*100)/100;logMove(p.id,'sale',-it.qty,b,p.stock,'فاتورة #'+inv.num,it.moveId);}});
 DB.invoices.push(inv);
 devs.forEach(d=>{d.status='sold';d.invoiceId=inv.id;d.customerId=P.customerId;d.soldAt=now;d.salePrice=d.price;d.warrantyEnd=d.warrantyMonths?addMonthsISO(now,d.warrantyMonths):null;});
 let contract=null;
 if(P.mode==='inst'){contract={id:uid(),invoiceId:inv.id,invoiceNum:inv.num,customerId:P.customerId,deviceIds:devs.map(d=>d.id),price,down:calc.down,feeMode:P.feeMode,feePct:num(P.feePct),fee,total:calc.total,months:P.months,payDay:Math.min(28,Math.max(1,num(P.payDay)||5)),guarantor:P.guarantor,guarantorPhone:P.gphone,createdAt:now,schedule:calc.sched};}
 save();enqueue({type:'invoice',table:'invoices',rowId:inv.id,payload:Object.assign({},inv)});
 devs.forEach(d=>{enqueue({type:'upsert',table:'devices',rowId:d.id,row:ENT.devices.map(d)});});
 if(contract){DB.contracts.push(contract);save();enqueue({type:'upsert',table:'installment_contracts',rowId:contract.id,row:ENT.contracts.map(contract)});}
 const wd=devs.find(d=>d.warrantyMonths);mobCart=[];mobPay=Object.assign({},mobPay,{customerId:'',paid:'',down:'',guarantor:'',gphone:'',feeTotal:'',mode:'cash'});
 closeSheet();go(contract?'#/inst':'#/devices');render();toast('البيع اتسجل ✓'+(contract?' — اتعمل جدول الأقساط':''));
 if(wd&&confirm('تطبع شهادة الضمان دلوقتي؟'))printWarranty(wd.id);}
/* ---------- التقسيط ---------- */
state.iqf='act';
function vInst(){const cs=DB.contracts.filter(c=>!c.deleted);const act=cs.filter(c=>instLeft(c)>0.005),done=cs.filter(c=>instLeft(c)<=0.005),late=act.filter(c=>instLate(c).length);
 const list=(state.iqf==='late'?late:state.iqf==='done'?done:act).slice().sort((a,b)=>{const na=instNext(a),nb=instNext(b);return (na?new Date(na.due):0)-(nb?new Date(nb.due):0);});
 const ch=(k,l,n)=>`<button class="chip${state.iqf===k?' on':''}" onclick="state.iqf='${k}';render()">${l} (${fmt(n)})</button>`;
 const card=c=>{const cu=cust(c.customerId);const nx=instNext(c);const lt=instLate(c);const paidN=c.schedule.filter(x=>x.paidAmt>=x.amt-0.005).length;
  return `<button class="row" onclick="openContract('${c.id}')"><div class="ic" style="background:${lt.length?'var(--red-soft);color:var(--red)':'var(--blue-soft);color:var(--blue)'}">${ic('cash')}</div><div class="mid"><div class="t">${esc(cu?cu.name:'عميل')}</div><div class="s">مدفوع ${fmt(paidN)} من ${fmt(c.months)} · متبقي ${fmt(instLeft(c))} ج</div>${nx?`<div class="s">القسط الجاي ${new Date(nx.due).toLocaleDateString(AR,{day:'numeric',month:'long'})} · ${fmt(nx.amt-nx.paidAmt)} ج</div>`:''}</div><div class="end">${lt.length?`<span class="badge b-red">متأخر ${fmt(lt.length)}</span>`:nx?'<span class="badge b-green">ماشي</span>':'<span class="badge b-green">خالص ✓</span>'}</div></button>`;};
 return mobHead('التقسيط','عقود وأقساط العملاء')+`<div class="content"><div class="chips">${ch('act','شغالة',act.length)}${ch('late','متأخرة',late.length)}${ch('done','خالصة',done.length)}</div>${list.length?list.map(card).join(''):`<div class="empty"><div class="big">مفيش عقود هنا</div>اعمل بيع بالتقسيط من "بيع جهاز"</div>`}</div>`+navbar('inst');}
function openContract(id){const c=DB.contracts.find(x=>x.id===id);if(!c)return;const cu=cust(c.customerId);const nx=instNext(c);const now=Date.now();
 const cal=c.schedule.map(x=>{const paid=x.paidAmt>=x.amt-0.005,part=x.paidAmt>0&&!paid,late=!paid&&new Date(x.due)<now;const m=new Date(x.due).toLocaleDateString(AR,{month:'short'});return `<div class="mbm ${paid?'pd':late?'lt':nx&&nx.n===x.n?'nx':''}">${m}<br><b>${paid?'✓':fmt(x.amt-x.paidAmt)}</b>${part?'<br>جزئي':''}</div>`;}).join('');
 const r=(k,v)=>`<div class="trow"><span class="k">${k}</span><span style="font-weight:800">${v}</span></div>`;
 const devs=c.deviceIds.map(i=>DB.devices.find(d=>d.id===i)).filter(Boolean);
 sheet('عقد تقسيط · '+esc(cu?cu.name:''),`<div class="total-card">${devs.map(d=>r(esc(devName(d)),`<span class="mbimei">${imeiFmt(d.imei)}</span>`)).join('')}${r('إجمالي المقسّط',fmt(c.total)+' ج')}${r('المدفوع',fmt(instPaid(c))+' ج')}${r('المتبقي','<span style="color:var(--red)">'+fmt(instLeft(c))+' ج</span>')}${c.guarantor?r('الضامن',esc(c.guarantor)+(c.guarantorPhone?' · '+esc(c.guarantorPhone):'')):''}</div>
<div class="mbcal">${cal}</div>${nx?`<div class="field" style="margin-top:12px"><div class="lbl">تحصيل (القسط الجاي ${fmt(nx.amt-nx.paidAmt)} ج)</div><input id="ic-amt" inputmode="decimal" value="${nx.amt-nx.paidAmt}"></div><div style="display:flex;gap:8px"><button class="btn btn-p" onclick="collectInst('${c.id}')">تحصيل ✓</button><button class="btn" style="background:var(--green-soft);color:var(--green)" onclick="waInst('${c.id}')">واتساب تذكير</button></div>`:'<div class="note" style="margin-top:10px">العقد خالص ✓</div>'}`);}
function collectInst(id){const c=DB.contracts.find(x=>x.id===id);let amt=num($('#ic-amt')?.value);if(amt<=0){toast('اكتب المبلغ');return;}if(amt>instLeft(c)+0.005){toast('المبلغ أكبر من المتبقي');return;}
 const pay={id:uid(),date:_nowIso(),kind:'in',partyId:c.customerId,partyType:'c',amount:amt,note:'قسط عقد تقسيط #'+(c.invoiceNum||''),method:'كاش'};DB.payments.push(pay);
 let left=amt;for(const x of c.schedule){if(left<=0.004)break;const need=Math.round((x.amt-x.paidAmt)*100)/100;if(need<=0)continue;const t=Math.min(need,left);x.paidAmt=Math.round((x.paidAmt+t)*100)/100;left=Math.round((left-t)*100)/100;if(x.paidAmt>=x.amt-0.005)x.paidAt=_nowIso();}
 save();enqueue({type:'payment',table:'payments',rowId:pay.id,payload:pay});mobSave('contracts',c);closeSheet();render();toast('القسط اتحصّل ✓');}
function waInst(id){const c=DB.contracts.find(x=>x.id===id);const cu=cust(c.customerId);const nx=instNext(c);if(!nx)return;const u=waLink(cu&&cu.phone,'أ/ '+cu.name+'، تحية طيبة 🌹 فاضل عليك قسط '+fmt(nx.amt-nx.paidAmt)+' ج ميعاده '+new Date(nx.due).toLocaleDateString(AR,{day:'numeric',month:'long'})+' — '+DB.settings.shopName);if(!u){toast('مفيش رقم تليفون للعميل');return;}window.open(u,'_blank');}
/* ---------- الصيانة ---------- */
state.rf='open';const RS={recv:['استلام','mb-a'],work:['بتتصلح','mb-b'],ready:['جاهز للتسليم','mb-g'],done:['اتسلّم','mb-m']};
function vRepairs(){const all=DB.tickets.filter(t=>!t.deleted);const f=t=>state.rf==='open'?t.status!=='done':state.rf==='all'?true:t.status===state.rf;const list=all.filter(f).sort((a,b)=>b.num-a.num);
 const cnt=k=>all.filter(t=>k==='open'?t.status!=='done':k==='all'?true:t.status===k).length;const ch=(k,l)=>`<button class="chip${state.rf===k?' on':''}" onclick="state.rf='${k}';render()">${l} (${fmt(cnt(k))})</button>`;
 return mobHead('الصيانة','تذاكر الصيانة',`<button class="avatar" style="background:var(--green)" onclick="openTicketSheet()">${ic('plus',22)}</button>`)+`<div class="content"><div class="chips">${ch('open','مفتوحة')}${ch('recv','استلام')}${ch('work','بتتصلح')}${ch('ready','جاهز')}${ch('done','اتسلّم')}</div>
${list.length?list.map(t=>`<button class="row mbk mbk-${t.status}" onclick="openTicketDetail('${t.id}')"><div class="mid"><div class="t">#${fmt(t.num)} · ${esc(t.model||'جهاز')}</div><div class="s">${esc(t.fault)} · ${esc(t.customerName||'')}</div>${t.underWarranty?'<div class="s"><span class="mbb mb-g">تحت الضمان</span></div>':''}</div><div class="end"><span class="mbb ${RS[t.status][1]}">${RS[t.status][0]}</span><div class="s">${fmt(t.fee||t.estimate||0)} ج</div></div></button>`).join(''):`<div class="empty"><div class="big">مفيش تذاكر</div>اضغط ＋ لاستلام جهاز صيانة</div>`}</div>`+navbar('rep');}
function openTicketSheet(id,devId){const t=id?DB.tickets.find(x=>x.id===id):null;const dev=devId?DB.devices.find(x=>x.id===devId):(t&&t.deviceId?DB.devices.find(x=>x.id===t.deviceId):null);const c=dev&&cust(dev.customerId);
 const f=(k,l,v,ph,ex)=>`<div class="field"><div class="lbl">${l}</div><input id="tk-${k}" value="${esc(v??'')}" placeholder="${ph||''}" ${ex||''}></div>`;
 sheet(t?'تعديل تذكرة':'تذكرة صيانة جديدة',`<input type="hidden" id="tk-dev" value="${dev?dev.id:''}">${dev?`<div class="note" style="margin-bottom:10px">${dev.warrantyEnd&&warrDays(dev)>=0?'✓ الجهاز تحت الضمان — لحد '+new Date(dev.warrantyEnd).toLocaleDateString(AR):'الجهاز من المحل — الضمان منتهي'}</div>`:''}
<div class="g2m">${f('name','اسم العميل',t?.customerName??c?.name,'')}${f('phone','التليفون',t?.customerPhone??c?.phone,'','inputmode="tel"')}${f('model','الموديل',t?.model??(dev?devName(dev):''),'')}${f('imei','IMEI',t?.imei??dev?.imei,'','inputmode="numeric" style="direction:ltr;text-align:left"')}</div>
${f('fault','العطل',t?.fault,'كسر شاشة…')}${f('cond','حالة الجهاز عند الاستلام',t?.condition,'خدوش · بدون شريحة')}
<div class="g2m">${f('est','تكلفة متوقعة',t?.estimate,'','inputmode="decimal"')}${f('dep','عربون',t?.deposit,'','inputmode="decimal"')}</div>
<button class="btn btn-p" style="width:100%" onclick="saveTicket('${id||''}')">${t?'حفظ ✓':'حفظ وطباعة إيصال الاستلام'}</button>`);}
function saveTicket(id){const g=k=>($('#tk-'+k)?.value||'').trim();if(!g('fault')||!g('name')){toast('اكتب اسم العميل والعطل');return;}
 const old=id?DB.tickets.find(x=>x.id===id):null;const devId=$('#tk-dev')?.value||'';const dev=devId?DB.devices.find(x=>x.id===devId):DB.devices.find(x=>x.imei&&x.imei===g('imei').replace(/\D/g,''));
 const t=Object.assign({},old||{id:uid(),num:DB.tickets.reduce((m,x)=>Math.max(m,x.num||0),0)+1,status:'recv',createdAt:_nowIso()},{customerName:g('name'),customerPhone:g('phone'),model:g('model'),imei:g('imei').replace(/\D/g,''),fault:g('fault'),condition:g('cond'),estimate:num(g('est')),deposit:num(g('dep')),deviceId:dev?dev.id:'',underWarranty:!!(dev&&dev.status==='sold'&&dev.warrantyEnd&&warrDays(dev)>=0)});
 if(!old&&t.deposit>0){const x={id:uid(),date:_nowIso(),kind:'in',label:'عربون صيانة #'+t.num,amount:t.deposit,note:t.customerName};DB.drawer.push(x);enqueue({type:'drawer',table:'drawer_entries',rowId:x.id,payload:x});}
 else if(old&&t.deposit!==old.deposit){/* تعديل العربون بعد التسجيل مش بيغيّر الدرج — سجّل الفرق يدوي */}
 mobSave('tickets',t);closeSheet();render();toast('اتحفظت ✓');if(!old)setTimeout(()=>printTicket(t.id),100);}
function printTicket(id){const t=DB.tickets.find(x=>x.id===id);if(!t)return;$('#print-area').innerHTML=`<div class="p-head"><h1>${esc(DB.settings.shopName)}</h1><p>إيصال استلام صيانة #${t.num}</p></div><div style="font-size:14px;line-height:2.1;padding:6mm"><b>العميل:</b> ${esc(t.customerName)} ${esc(t.customerPhone)}<br><b>الجهاز:</b> ${esc(t.model)} <span dir="ltr">${esc(t.imei)}</span><br><b>العطل:</b> ${esc(t.fault)}<br><b>حالة الجهاز:</b> ${esc(t.condition)}<br><b>التكلفة المتوقعة:</b> ${fmt(t.estimate)} ج · <b>العربون:</b> ${fmt(t.deposit)} ج<br><small>التاريخ ${new Date(t.createdAt).toLocaleDateString(AR)}</small></div>`;setTimeout(()=>window.print(),80);}
function openTicketDetail(id){const t=DB.tickets.find(x=>x.id===id);if(!t)return;const r=(k,v)=>`<div class="trow"><span class="k">${k}</span><span style="font-weight:800">${v}</span></div>`;
 const nextBtn=t.status==='recv'?`<button class="btn btn-p" onclick="tkStatus('${t.id}','work')">بدأت الصيانة</button>`:t.status==='work'?`<div class="field" style="width:100%"><div class="g2m"><div><div class="lbl">تكلفة القطع</div><input id="tk-part" inputmode="decimal" value="${t.partCost||''}"></div><div><div class="lbl">السعر النهائي للعميل</div><input id="tk-fee" inputmode="decimal" value="${t.fee||t.estimate||''}"></div></div></div><button class="btn btn-p" onclick="tkReady('${t.id}')">جاهز للتسليم ✓</button>`:t.status==='ready'?`<button class="btn btn-p" onclick="tkDeliver('${t.id}')">تسليم وتحصيل ${fmt(Math.max(0,(t.fee||0)-(t.deposit||0)))} ج</button><button class="btn" style="background:var(--green-soft);color:var(--green)" onclick="waTicket('${t.id}')">واتساب: جهازك جاهز</button>`:`<div class="note">اتسلّم ${t.deliveredAt?new Date(t.deliveredAt).toLocaleDateString(AR):''}${t.warrantyEnd?' · ضمان الصيانة لحد '+new Date(t.warrantyEnd).toLocaleDateString(AR):''}</div>`;
 sheet('تذكرة #'+fmt(t.num),`<div class="total-card">${r('الحالة',`<span class="mbb ${RS[t.status][1]}">${RS[t.status][0]}</span>`)}${r('العميل',esc(t.customerName)+' · '+esc(t.customerPhone))}${r('الجهاز',esc(t.model)+(t.imei?' <span class="mbimei">'+imeiFmt(t.imei)+'</span>':''))}${r('العطل',esc(t.fault))}${r('الحالة عند الاستلام',esc(t.condition||'—'))}${r('عربون / متوقع',fmt(t.deposit)+' / '+fmt(t.estimate)+' ج')}${t.fee?r('السعر النهائي',fmt(t.fee)+' ج')+(isFinite(t.partCost)&&t.partCost?r('ربح الصيانة',fmt(t.fee-t.partCost)+' ج'):''):''}${t.underWarranty?r('الضمان','<span class="mbb mb-g">تحت ضمان البيع</span>'):''}</div>
<div style="display:flex;gap:8px;margin-top:12px;flex-wrap:wrap">${nextBtn}<button class="btn" style="background:var(--card);border:1px solid var(--line)" onclick="closeSheet();openTicketSheet('${t.id}')">تعديل</button><button class="btn" style="background:var(--card);border:1px solid var(--line)" onclick="printTicket('${t.id}')">طباعة</button></div>`);}
function tkStatus(id,s){const t=DB.tickets.find(x=>x.id===id);t.status=s;mobSave('tickets',t);closeSheet();render();}
function tkReady(id){const t=DB.tickets.find(x=>x.id===id);t.partCost=num($('#tk-part')?.value);t.fee=t.underWarranty&&!num($('#tk-fee')?.value)?0:num($('#tk-fee')?.value);if(t.fee<=0&&!t.underWarranty){toast('اكتب السعر النهائي');return;}t.status='ready';t.readyAt=_nowIso();mobSave('tickets',t);closeSheet();render();toast('جاهزة — ابعت واتساب للعميل');}
function tkDeliver(id){const t=DB.tickets.find(x=>x.id===id);const rest=Math.max(0,(t.fee||0)-(t.deposit||0));
 if(rest>0){const x={id:uid(),date:_nowIso(),kind:'in',label:'تسليم صيانة #'+t.num,amount:rest,note:t.customerName};DB.drawer.push(x);enqueue({type:'drawer',table:'drawer_entries',rowId:x.id,payload:x});}
 t.status='done';t.deliveredAt=_nowIso();t.warrantyEnd=new Date(Date.now()+30*86400000).toISOString();mobSave('tickets',t);closeSheet();render();toast('اتسلّمت ✓');}
function waTicket(id){const t=DB.tickets.find(x=>x.id===id);const u=waLink(t.customerPhone,'أ/ '+t.customerName+'، جهازك '+t.model+' جاهز للتسليم 🌹 المتبقي '+fmt(Math.max(0,(t.fee||0)-(t.deposit||0)))+' ج — '+DB.settings.shopName);if(!u){toast('مفيش رقم تليفون');return;}window.open(u,'_blank');}
/* ---------- بحث الضمان ---------- */
state.wq='';
function warrantyResults(){const q=(state.wq||'').trim().toLowerCase();if(q.length<3)return '<div class="empty"><div class="big">اكتب آخر أرقام IMEI أو تليفون العميل</div></div>';
 const ds=DB.devices.filter(d=>!d.deleted&&d.status==='sold'&&(d.imei.includes(q)||(cust(d.customerId)?.phone||'').includes(q)||(cust(d.customerId)?.name||'').toLowerCase().includes(q)));
 return ds.length?ds.map(d=>{const c=cust(d.customerId);const inv=DB.invoices.find(i=>i.id===d.invoiceId);const tk=DB.tickets.filter(t=>!t.deleted&&t.deviceId===d.id).length;
  return `<div class="total-card"><div class="row" style="background:none;border:0;padding:0"><div class="mid"><div class="t">${esc(devName(d))}</div><div class="s"><span class="mbimei">${imeiFmt(d.imei)}</span></div></div>${warrBadge(d)}</div>
<div class="trow"><span class="k">اتباع لـ</span><b>${esc(c?c.name:'')} ${esc(c?.phone||'')}</b></div><div class="trow"><span class="k">تاريخ البيع</span><b>${new Date(d.soldAt).toLocaleDateString(AR)}</b></div><div class="trow"><span class="k">الضمان ينتهي</span><b>${d.warrantyEnd?new Date(d.warrantyEnd).toLocaleDateString(AR):'بدون ضمان'}</b></div><div class="trow"><span class="k">فاتورة / تذاكر صيانة</span><b>${inv?'#'+inv.num.toLocaleString(AR):'—'} / ${fmt(tk)}</b></div>
<div style="display:flex;gap:8px;margin-top:8px"><button class="btn btn-p" onclick="openTicketSheet('','${d.id}')">فتح تذكرة صيانة</button><button class="btn" style="background:var(--card);border:1px solid var(--line)" onclick="printWarranty('${d.id}')">طباعة الشهادة</button></div></div>`;}).join(''):'<div class="empty"><div class="big">مفيش جهاز بالبيانات دي</div></div>';}
function vWarranty(){return mobHead('الضمان','دوّر بالـ IMEI أو تليفون العميل')+`<div class="content"><div class="search">${ic('search',18)}<input placeholder="IMEI أو تليفون أو اسم…" value="${esc(state.wq)}" oninput="state.wq=this.value;$('#wres').innerHTML=warrantyResults()"></div><div id="wres">${warrantyResults()}</div></div>`+navbar('');}
