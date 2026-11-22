BEGIN;
INSERT INTO auth.users(id,email) VALUES('00000000-0000-0000-0000-000000000123','fixture@invalid.example');
SELECT set_config('request.jwt.claim.sub','c9dff448-021e-456e-914e-d1a63202c62d',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE tid uuid; n integer; rejected boolean:=false; BEGIN
 tid:=public.admin_finish_shop('00000000-0000-0000-0000-000000000123','fixture@invalid.example','fixture','fixture','',1);
 SELECT count(*) INTO n FROM shop_users WHERE tenant_id=tid AND auth_id='00000000-0000-0000-0000-000000000123';
 IF n<>1 THEN RAISE EXCEPTION 'FAIL tenant membership'; END IF;
 BEGIN PERFORM public.admin_finish_shop('00000000-0000-0000-0000-000000000123','fixture@invalid.example','fixture','fixture','',1);
 EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'FAIL duplicate assignment'; END IF;
END $$;
RESET ROLE;
SELECT 'PASS: atomic provisioning and duplicate rejection' result;
ROLLBACK;