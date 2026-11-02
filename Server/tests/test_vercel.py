from dataclasses import replace
import os
import secrets
import pytest
from fastapi.testclient import TestClient
from nosce.config import Settings
from nosce.database import Store
from nosce.admin import password_hash
from nosce.main import create_app
from nosce.apple_services import Billing
from nosce.models import Instrument, now
from nosce.providers import MarketHub
from test_service import session,Sender
from test_commerce import tx,Verifier
from test_no_login import StoreVerifier


@pytest.fixture
def postgres_settings():
    url=os.getenv('NOSCE_TEST_POSTGRES')
    if not url:pytest.skip('Set NOSCE_TEST_POSTGRES to run the persistent PostgreSQL integration tests')
    cfg=Settings(database=url,token_key='06'*32,serverless=True,admin_password_hash=password_hash('test-only-password-long'),
                 app_store_environment='Sandbox',app_store_products='pro.monthly')
    store=Store(url,cfg.token_key)
    store.db.execute('TRUNCATE installs,sessions,users,orders,limits,ended,auth_challenges,admin_sessions,admin_totp,audit,renewals,apple_events,reconciliations,runtime_cache RESTART IDENTITY CASCADE')
    store.close();return cfg


def test_password_only_login_across_instances_and_rotation(postgres_settings):
    cfg=postgres_settings
    first=create_app(cfg,run_workers=False);second=create_app(cfg,run_workers=False)
    with TestClient(first,base_url='https://api.test') as a,TestClient(second,base_url='https://api.test') as b:
        assert a.get('/admin/api/config').json()['requiresTotp'] is False
        assert a.post('/admin/api/login',json={'username':'admin','password':'wrong'}).status_code==401
        result=a.post('/admin/api/login',json={'username':'admin','password':'test-only-password-long'})
        assert result.status_code==200
        cookie=a.cookies.get('nosce_admin');assert cookie
        b.cookies.set('nosce_admin',cookie,domain='api.test',path='/admin')
        assert b.get('/admin/api/session').status_code==200
        assert b.get('/admin/api/overview').json()['database']=='PostgreSQL'
        assert b.post('/admin/api/logout').status_code==403
        csrf=b.get('/admin/api/session').json()['csrf']
        assert b.post('/admin/api/logout',headers={'X-CSRF-Token':csrf}).status_code==200
        assert a.get('/admin/api/session').status_code==401


@pytest.mark.asyncio
async def test_postgres_anonymous_purchase_restore_and_refund(postgres_settings):
    cfg=postgres_settings;store=Store(cfg.database,cfg.token_key)
    first,_=store.register();second,_=store.register();verifier=StoreVerifier();billing=Billing(cfg,store,verifier)
    profile=await billing.link_store(first,'verified-app-transaction');user=profile['userId']
    value=tx(user,appTransactionId='app-123');verifier.value=value
    await billing.submit(first,'test-only-signed-payload')
    restored=await billing.link_store(second,'verified-app-transaction')
    assert restored['userId']==user and restored['pro']
    # A second Store instance reads the same order and cannot bypass the purchase ownership check.
    other=Store(cfg.database,cfg.token_key);assert other.user(second)['id']==user
    billing.save(tx(user,appTransactionId='app-123',signedDate=value.signedDate+1000,revocationDate=value.signedDate))
    assert not billing.profile(second)['pro']
    billing.save(value);assert not billing.profile(first)['pro']
    assert other.db.execute('SELECT count(*) FROM orders').fetchone()[0]==1
    other.close();store.close()


def test_postgres_activity_ownership_persistence_and_limits(postgres_settings):
    cfg=postgres_settings;a=Store(cfg.database,cfg.token_key);install,_=a.register()
    ids=['hl:asset'+str(i) for i in range(8)];a.upsert(install,session(symbols=ids),100,64)
    b=Store(cfg.database,cfg.token_key)
    assert len(b.selected())==8 and b.token(b.sessions()[0])=='a'*64
    other,_=b.register()
    with pytest.raises(PermissionError):b.upsert(other,session(symbols=ids),100,64)
    assert a.limit('cross-instance',1,300) and not b.limit('cross-instance',1,300)
    a.cleanup();assert b.sessions()
    b.delete(install,'activity-1');assert not a.sessions()
    a.close();b.close()


def test_serverless_readiness_requires_live_worker(postgres_settings):
    cfg=postgres_settings;store=Store(cfg.database,cfg.token_key)
    store.put_cache('catalog',[Instrument(id='hl:BTC',symbol='BTC',name='BTC',market='Crypto',currency='USD',provider='hyperliquid',provider_symbol='BTC').model_dump()])
    store.put_cache('heartbeat',{'hlEvents':10,'binanceEvents':0})
    app=create_app(cfg,injected_store=store,run_workers=False)
    with TestClient(app,base_url='https://api.test') as c:
        state=c.get('/readyz').json();assert state['workerOnline'] and state['marketCatalog']
        assert not state['ready'] # No APNs credentials: never advertise background delivery as ready.
        bearer=c.post('/v1/installations').json()['token']
        headers={'Authorization':'Bearer '+bearer}
        assert c.get('/v1/catalog',headers=headers).json()['instruments'][0]['id']=='hl:BTC'
        store.db.execute('UPDATE runtime_cache SET updated=? WHERE key=?',(now()-100,'heartbeat'))
        assert not c.get('/readyz').json()['workerOnline']


def test_vercel_refuses_ephemeral_database(monkeypatch):
    monkeypatch.setenv('VERCEL','1');monkeypatch.delenv('DATABASE_URL',raising=False)
    monkeypatch.setenv('TOKEN_ENCRYPTION_KEY','06'*32)
    with pytest.raises(ValueError,match='PostgreSQL'):Settings.from_env().validate()


def test_password_only_configuration_and_mobile_login(tmp_path,monkeypatch):
    monkeypatch.setenv('ADMIN_USERNAME','owner')
    monkeypatch.setenv('ADMIN_PASSWORD','a-test-password-long-enough')
    monkeypatch.delenv('ADMIN_PASSWORD_HASH',raising=False)
    monkeypatch.delenv('ADMIN_TOTP_SECRET',raising=False)
    monkeypatch.delenv('VERCEL',raising=False)
    monkeypatch.delenv('NOSCE_RUNTIME',raising=False)
    monkeypatch.delenv('DATABASE_URL',raising=False)
    monkeypatch.setenv('DATABASE',str(tmp_path/'admin.sqlite'))
    monkeypatch.setenv('TOKEN_ENCRYPTION_KEY','06'*32)
    cfg=Settings.from_env();cfg.validate()
    app=create_app(cfg,run_workers=False)
    with TestClient(app,base_url='https://api.test') as c:
        config=c.get('/admin/api/config').json();assert config['configured'] and not config['requiresTotp']
        page=c.get('/admin',headers={'User-Agent':'iPhone Safari'}).text
        assert 'autocomplete="current-password"' in page and 'font-size:16px' in page
        assert 'showPassword' in page and 'data-label' in page
        response=c.post('/admin/api/login',json={'username':'owner','password':'a-test-password-long-enough'})
        assert response.status_code==200 and 'httponly' in response.headers['set-cookie'].lower()
        cookie=c.cookies.get('nosce_admin')
        assert cookie and 'a-test-password' not in page


def test_unconfigured_vercel_shows_setup_without_default_password(monkeypatch):
    import importlib,sys
    for key in ['DATABASE_URL','ADMIN_PASSWORD','ADMIN_PASSWORD_HASH','TOKEN_ENCRYPTION_KEY']:
        monkeypatch.delenv(key,raising=False)
    sys.modules.pop('nosce.vercel_entry',None)
    module=importlib.import_module('nosce.vercel_entry')
    with TestClient(module.app,base_url='https://api.test') as c:
        assert c.get('/admin').status_code==200
        config=c.get('/admin/api/config').json()
        assert not config['configured'] and 'DATABASE_URL' in config['missing']
        assert c.post('/admin/api/login',json={'username':'admin','password':'admin'}).status_code==503


@pytest.mark.asyncio
async def test_restore_stays_available_when_new_sales_are_paused(tmp_path):
    from test_commerce import cfg as fixture_cfg
    cfg=fixture_cfg(tmp_path,sales_enabled=False)
    store=Store(':memory:',cfg.token_key);install,_=store.register()
    verifier=StoreVerifier();billing=Billing(cfg,store,verifier)
    profile=await billing.link_store(install,'verified-app-transaction')
    assert not profile['purchaseEnabled'] and profile['verificationEnabled'] and profile['productIds']==['pro.monthly']
    verifier.value=tx(profile['userId'],appTransactionId='app-123')
    assert (await billing.submit(install,'test-only-signed-payload'))['pro']


def test_postgres_foreground_subscriptions_are_shared_with_worker(postgres_settings):
    cfg=postgres_settings;store=Store(cfg.database,cfg.token_key);owner,_=store.register()
    api_hub=MarketHub(cfg,store);worker_hub=MarketHub(cfg,Store(cfg.database,cfg.token_key))
    api_hub.watch(owner,'first',['hl:BTC','hl:ETH'])
    assert worker_hub.selected()=={'hl:BTC','hl:ETH'}
    worker_hub.watch(owner,'second',['hl:SOL'])
    api_hub.unwatch(owner,'first')
    assert worker_hub.selected()=={'hl:SOL'}
    worker_hub.unwatch(owner,'second')
    assert not api_hub.selected()
