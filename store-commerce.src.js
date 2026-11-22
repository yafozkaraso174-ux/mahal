/* Store pricing uses the same pure quote engine as owner sales. */
let storeOffers=[];
function cmStoreRefresh(){let changed=false;for(const p of products||[]){if(p.originalPrice==null)p.originalPrice=p.price;const q=cmQuote(storeOffers,p.id,p.originalPrice);if(p.price!==q.price)changed=true;p.price=q.price;p.offer=q.offer;}return changed;}
function cmStoreQty(id,value){const p=products.find(x=>x.id===id),q=cmNumber(value);if(!p||!Number.isFinite(q)||q<=0||q>p.stock){toast('راجع الكمية المتاحة');return;}try{cmQuantity({...p,unitConfig:p.unit_config},'base',q);}catch(e){toast(e.message);return;}cart[id]=q;saveCart();openCart();render();}
