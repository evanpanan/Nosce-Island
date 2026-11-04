from dataclasses import replace
import json
import httpx
from fastapi.testclient import TestClient
from nosce.main import create_app
from nosce.database import Store
from nosce.providers import MarketHub
from nosce.operator_settings import KEY
from test_commerce import cfg
from test_vercel import postgres_settings


def login(c):
    r=c.post('/admin/api/login',json={'username':'admin','password':'test-administrator-password'})
    assert r.status_code==200
    return {'X-CSRF-Token':r.json()['csrf']}


def test_saved_config_is_encrypted_private_revisioned_and_effective_without_redeploy(tmp_path):
    settings=cfg(tmp_path)
    from nosce.admin import password_hash
    settings=replace(settings,admin_password_hash=password_hash('test-administrator-password'))
    store=Store(':memory:',settings.token_key);install,token=store.register();_,other=store.register()
    user=store.user(install)['id'];hub=MarketHub(settings,store);requests=[]
    def upstream(request):
        requests.append(request)
        assert request.headers['APCA-API-KEY-ID']=='operator-key'
        assert request.headers['APCA-API-SECRET-KEY']=='operator-secret'
        if request.url.path=='/v2/assets':return httpx.Response(200,json=[{'symbol':'AAPL','name':'Apple','class':'us_equity','exchange':'NASDAQ','status':'active'}])
        return httpx.Response(200,json={'AAPL':{}})
    hub.client=httpx.AsyncClient(transport=httpx.MockTransport(upstream))
    app=create_app(settings,injected_store=store,injected_hub=hub,run_workers=False)
    with TestClient(app,base_url='https://test') as c:
        assert c.get('/admin/api/services/config').status_code==401
        assert c.post('/admin/api/services/config',json={'revision':0,'values':{}}).status_code==401
        csrf=login(c)
        assert c.get('/admin/api/services/config').json()['revision']==0
        values={'alpaca_key':'operator-key','alpaca_secret':'operator-secret','alpaca_personal_user':user}
        assert c.post('/admin/api/services/config',json={'revision':0,'values':values}).status_code==403
        saved=c.post('/admin/api/services/config',headers=csrf,json={'revision':0,'values':values});assert saved.status_code==200
        revision=saved.json()['revision']
        assert 'operator-secret' not in saved.text and 'operator-key' not in saved.text
        assert saved.json()['fields']['alpaca_secret']['configured']
        assert saved.json()['fields']['alpaca_secret']['source']=='后台保存'
        raw=store.db.execute('SELECT payload FROM runtime_cache WHERE key=?',(KEY,)).fetchone()[0]
        assert 'operator-secret' not in raw and 'operator-key' not in raw
        described=c.get('/admin/api/services/config');assert 'operator-secret' not in described.text and 'operator-key' not in described.text
        assert described.json()['fields']['alpaca_secret']['configured']
        assert described.json()['fields']['alpaca_secret']['value'] is None
        assert c.post('/admin/api/services/config',headers=csrf,json={'revision':0,'values':{'alpaca_secret':'replacement'}}).status_code==409
        assert c.post('/admin/api/services/config',headers=csrf,json={'revision':revision,'values':{'token_key':'do-not-allow'}}).status_code==422
        # FastAPI validation errors must not echo input credential objects.
        invalid=c.post('/admin/api/services/config',headers=csrf,json={'revision':'operator-secret','values':values})
        assert invalid.status_code==422 and 'operator-secret' not in invalid.text
        assert c.post('/admin/api/services/alpaca/test',json={}).status_code==403
        result=c.post('/admin/api/services/alpaca/test',headers=csrf,json={})
        assert result.status_code==200 and result.json()['assetCount']==1 and not result.json()['quoteAvailable']
        # No sample price is claimed when credentials are valid but the symbol has no latest trade.
        assert 'operator-secret' not in result.text
        cached,_=store.get_cache('alpaca:catalog')
        assert len(cached)==1 and cached[0]['symbol']=='AAPL'
        provider_calls=len(requests)
        other_catalog=c.get('/v1/catalog',headers={'Authorization':'Bearer '+other}).json()
        assert other_catalog['instruments']==[] and other_catalog['stockStatus']=='restricted'
        own=c.get('/v1/catalog',headers={'Authorization':'Bearer '+token}).json()
        assert own['stockStatus']=='ready' and own['instruments'][0]['provider']=='alpaca'
        assert len(requests)==provider_calls # Connection test publishes the actual verified catalog for the app.
        # A new instance independently loads the encrypted database setting, without shared process state.
        second=create_app(settings,injected_store=store,injected_hub=hub,run_workers=False)
        with TestClient(second,base_url='https://test') as c2:
            r=c2.get('/v1/catalog',headers={'Authorization':'Bearer '+token})
            assert r.status_code==200 and r.json()['stockStatus']=='ready'


def test_blank_secret_preserves_value_and_invalid_fields_never_commit(tmp_path):
    from nosce.operator_settings import RuntimeSettings
    settings=cfg(tmp_path);store=Store(':memory:',settings.token_key);runtime=RuntimeSettings(settings,store)
    import pytest
    first=runtime.save({'alpaca_secret':'private-fixture'},0,[])
    second=runtime.save({'alpaca_secret':''},first['revision'],[])
    with runtime.bind():assert runtime.alpaca_secret=='private-fixture'
    with pytest.raises(ValueError):runtime.save({'apns_key_pem':'not-a-key'},second['revision'],[])
    with pytest.raises(ValueError):runtime.save({'alpaca_personal_user':'unknown'},second['revision'],[])
    with pytest.raises(ValueError):runtime.save({'database':'https://bad'},second['revision'],[])
    with runtime.bind():assert runtime.alpaca_secret=='private-fixture' and not runtime.apns_key_pem


def test_runtime_config_persists_across_postgres_instances(postgres_settings):
    from nosce.operator_settings import RuntimeSettings,ConfigConflict
    from nosce.apple_services import Billing
    import pytest
    store=Store(postgres_settings.database,postgres_settings.token_key)
    other=Store(postgres_settings.database,postgres_settings.token_key)
    first=RuntimeSettings(postgres_settings,store);second=RuntimeSettings(postgres_settings,other)
    _,rev=first.read()
    result=first.save({'alpaca_secret':'postgres-only-fixture','app_store_products':'new.product'},rev,[])
    with second.bind():
        assert second.alpaca_secret=='postgres-only-fixture'
        assert Billing(second,other).products=={'new.product'}
    with pytest.raises(ConfigConflict):second.save({'alpaca_secret':'conflicting'},rev,[])
    assert result['revision']==second.describe()['revision']
    raw=store.db.execute('SELECT payload FROM runtime_cache WHERE key=?',(KEY,)).fetchone()[0]
    assert 'postgres-only-fixture' not in raw
    store.db.execute('DELETE FROM runtime_cache WHERE key=?',(KEY,))
    other.close();store.close()


def test_apns_runtime_key_refresh_uses_saved_key_and_new_key_id(tmp_path):
    from nosce.operator_settings import RuntimeSettings
    from nosce.apns import APNs
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    import jwt
    settings=cfg(tmp_path);store=Store(':memory:',settings.token_key);runtime=RuntimeSettings(settings,store)
    sender=APNs(runtime)
    key=ec.generate_private_key(ec.SECP256R1()).private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
    revision=runtime.save({'apns_key_pem':key,'apns_team_id':'TESTTEAM','apns_key_id':'FIRSTKEY'},0,[])['revision']
    with runtime.bind():
        assert runtime.apns_configured
        assert jwt.get_unverified_header(sender.bearer())['kid']=='FIRSTKEY'
    runtime.save({'apns_key_id':'SECONDKEY'},revision,[])
    with runtime.bind():assert jwt.get_unverified_header(sender.bearer())['kid']=='SECONDKEY'
