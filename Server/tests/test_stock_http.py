from dataclasses import replace
from fastapi.testclient import TestClient
from nosce.admin import password_hash
from nosce.database import Store
from nosce.main import create_app
from nosce.models import now
from nosce.providers import MarketHub
from test_commerce import cfg


def setup(tmp_path,**changes):
    settings=cfg(tmp_path,td_key='test-only-key',td_display_rights=True,td_us_delay=0,td_hk_delay=900,**changes)
    store=Store(':memory:',settings.token_key);hub=MarketHub(settings,store)
    _,token=store.register();calls=[]
    async def upstream(endpoint,params):
        calls.append((endpoint,params))
        exchange=params['exchange'];symbol=params.get('symbol') or ('0700' if exchange=='HKEX' else 'AAPL' if exchange=='NASDAQ' else 'IBM')
        currency='HKD' if exchange=='HKEX' else 'USD'
        if endpoint=='stocks':return {'data':[{'exchange':exchange,'symbol':symbol,'name':'Test stock','currency':currency}]}
        return {'exchange':exchange,'symbol':symbol,'currency':currency,'close':'100','previous_close':'80',
                'timestamp':now()-(900 if exchange=='HKEX' else 0),'is_market_open':True}
    hub.td_get=upstream
    app=create_app(settings,injected_store=store,injected_hub=hub,run_workers=False)
    return app,store,hub,token,calls


def test_licensed_stock_catalog_and_http_quotes_work_without_worker(tmp_path):
    app,store,hub,token,calls=setup(tmp_path)
    with TestClient(app,base_url='https://api.test') as c:
        headers={'Authorization':'Bearer '+token}
        assert c.post('/v1/quotes',json={'symbols':['stock:NASDAQ:AAPL']}).status_code==401
        page=c.get('/v1/catalog',headers=headers);assert page.status_code==200
        values=page.json()['instruments'];assert {x['market'] for x in values}=={'US','HK'}
        assert {x['provider'] for x in values}=={'twelvedata'} and len(calls)==3
        assert 'test-only-key' not in page.text
        ids=['stock:NASDAQ:AAPL','stock:HKEX:0700']
        result=c.post('/v1/quotes',headers=headers,json={'symbols':ids});assert result.status_code==200
        quotes=result.json()['quotes'];assert len(quotes)==2 and {q['basis'] for q in quotes}=={'last'}
        hk=next(q for q in quotes if q['currency']=='HKD');assert hk['delaySeconds']==900 and hk['change']==25
        assert all(q['source'].startswith('Twelve Data') for q in quotes)
        assert len(calls)==5
        again=c.post('/v1/quotes',headers=headers,json={'symbols':ids});assert again.json()['quotes']==quotes
        assert len(calls)==5 # Shared catalog and per-symbol quote caches avoid repeated API credits.
        assert c.post('/v1/quotes',headers=headers,json={'symbols':['hl:BTC']}).status_code==422
        assert c.post('/v1/quotes',headers=headers,json={'symbols':[ids[0],ids[0]]}).status_code==422
        assert c.post('/v1/quotes',headers=headers,json={'symbols':['stock:NASDAQ:FAKE']}).status_code==422


def test_disabled_license_never_exposes_exchange_stock_quotes(tmp_path):
    app,store,hub,token,calls=setup(tmp_path)
    app= create_app(replace(hub.settings,td_display_rights=False),injected_store=store,injected_hub=hub,run_workers=False)
    with TestClient(app,base_url='https://api.test') as c:
        h={'Authorization':'Bearer '+token}
        assert c.get('/v1/catalog',headers=h).json()['instruments']==[]
        assert c.post('/v1/quotes',headers=h,json={'symbols':['stock:NASDAQ:AAPL']}).status_code==503
        assert calls==[]


def test_stock_failures_preserve_old_quotes_and_original_times(tmp_path):
    app,store,hub,token,calls=setup(tmp_path)
    with TestClient(app,base_url='https://api.test') as c:
        h={'Authorization':'Bearer '+token};ids=['stock:NASDAQ:AAPL']
        old=c.post('/v1/quotes',headers=h,json={'symbols':ids}).json()['quotes'][0]
        store.db.execute("UPDATE runtime_cache SET updated=? WHERE key LIKE ?",(now()-100,'stocks:%'))
        async def failed(*args):raise RuntimeError('Test provider outage')
        hub.td_get=failed
        result=c.post('/v1/quotes',headers=h,json={'symbols':ids});assert result.status_code==200
        assert result.json()['quotes'][0]==old


def test_market_permission_is_independent(tmp_path):
    app,store,hub,token,calls=setup(tmp_path)
    app=create_app(replace(hub.settings,td_hk_delay=-1),injected_store=store,injected_hub=hub,run_workers=False)
    with TestClient(app,base_url='https://api.test') as c:
        h={'Authorization':'Bearer '+token}
        page=c.get('/v1/catalog',headers=h).json();assert all(x['market']=='US' for x in page['instruments'])
        assert c.post('/v1/quotes',headers=h,json={'symbols':['stock:HKEX:0700']}).status_code==422
