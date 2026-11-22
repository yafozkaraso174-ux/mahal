BEGIN;
-- Everything below, including fixtures and counters, is rolled back.
UPDATE tenants SET status='active' WHERE id='6c239419-4891-4ecb-bab6-25532b26e8d5';
INSERT INTO products(id,name,tenant_id,stock) VALUES
 ('__isolation_own','isolation fixture','6c239419-4891-4ecb-bab6-25532b26e8d5',10);
INSERT INTO customers(id,name,tenant_id) VALUES
 ('__isolation_customer','fixture','6c239419-4891-4ecb-bab6-25532b26e8d5');
SELECT set_config('request.jwt.claim.sub',(SELECT id::text FROM auth.users WHERE email='testshop.e2e@gmail.com'),true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE n integer; rejected boolean:=false; result jsonb; BEGIN
 SELECT count(*) INTO n FROM products WHERE tenant_id<>public.my_tenant();
 IF n<>0 THEN RAISE EXCEPTION 'FAIL cross tenant SELECT'; END IF;
 UPDATE products SET stock=999 WHERE id='p1';
 GET DIAGNOSTICS n=ROW_COUNT;
 IF n<>0 THEN RAISE EXCEPTION 'FAIL cross tenant UPDATE'; END IF;
 BEGIN
  PERFORM public.save_invoice('{"id":"__isolation_bad","customerId":"__isolation_customer","items":[{"productId":"p1","qty":1}]}'::jsonb);
 EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'FAIL cross tenant RPC reference'; END IF;
 rejected:=false;
 BEGIN
  PERFORM public.admin_set_tenant_status('5336a072-d9eb-43d9-ac91-4d9d6572b781','suspended');
 EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'FAIL admin authorization'; END IF;
 result:=public.save_invoice('{"id":"__isolation_good","customerId":"__isolation_customer","items":[{"productId":"__isolation_own","qty":1}],"total":10,"paid":10}'::jsonb);
 IF result->>'tenant_id'<>public.my_tenant()::text THEN RAISE EXCEPTION 'FAIL invoice tenant'; END IF;
 SELECT stock INTO n FROM products WHERE id='__isolation_own';
 IF n<>9 THEN RAISE EXCEPTION 'FAIL own stock'; END IF;
END $$;
RESET ROLE;
UPDATE tenants SET status='suspended' WHERE id='6c239419-4891-4ecb-bab6-25532b26e8d5';
SET LOCAL ROLE authenticated;
DO $$ DECLARE n integer; rejected boolean:=false; BEGIN
 SELECT count(*) INTO n FROM products;
 IF n<>0 THEN RAISE EXCEPTION 'FAIL suspended read'; END IF;
 BEGIN PERFORM public.save_service_txn('{"id":"__isolation_block"}'::jsonb);
 EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'FAIL suspended write'; END IF;
END $$;
RESET ROLE;
SELECT 'PASS: cross-tenant read/write/RPC denial, own invoice/stock, admin denial, suspension' result;
ROLLBACK;
