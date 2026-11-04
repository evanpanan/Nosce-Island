from dataclasses import replace
from datetime import datetime,timezone,timedelta
from fastapi.testclient import TestClient
from nosce.main import create_app
from nosce.database import Store
from nosce.providers import MarketHub
from nosce.models import now
from test_commerce import cfg
import httpx


def setup(tmp_path):
    settings=cfg(tmp_path)
    store=Store(':memory:',settings.token_key)
    install,token=store.register();_,other=store.register()
    user=store.user(install)['id']
    settings=replace(settings,alpaca_key='fixture-id',alpaca_secret='fixture-secret',alpaca_personal_user=user)
    hub=MarketHub(settings,store);calls=[];state={'fail':False,'exchange':'V'}
    stamp=(datetime.now(timezone.utc)-timedelta(seconds=5)).isoformat()
    previous=(datetime.now(timezone.utc)-timedelta(days=1)).isoformat()
    def upstream(request):
        calls.append(request)
        assert request.headers['APCA-API-KEY-ID']=='fixture-id'
        assert request.headers['APCA-API-SECRET-KEY']=='fixture-secret'
        assert 'fixture' not in str(request.url)
        if state['fail']:return httpx.Response(503)
        if request.url.path=='/v2/assets':
            return httpx.Response(200,json=[{'class':'us_equity','status':'active','symbol':'AAPL','exchange':'NASDAQ','name':'Apple'},
                {'class':'us_equity','status':'active','symbol':'OTC','exchange':'OTC'},
                {'class':'crypto','status':'active','symbol':'BTC/USD','exchange':'CRYPTO'}])
        if request.url.path=='/v2/clock':return httpx.Response(200,json={'is_open':True})
        assert request.url.path=='/v2/stocks/snapshots' and request.url.params['feed']=='iex'
        return httpx.Response(200,json={'AAPL':{'latestTrade':{'p':100,'t':stamp,'x':state['exchange']},'prevDailyBar':{'c':80,'t':previous}}})
    hub.client=httpx.AsyncClient(transport=httpx.MockTransport(upstream))
    return settings,store,hub,token,other,calls,state


def test_personal_iex_is_private_real_catalog_batched_cached_and_source_labelled(tmp_path):
    settings,store,hub,token,other,calls,state=setup(tmp_path)
    with TestClient(create_app(settings,injected_store=store,injected_hub=hub,run_workers=False),base_url='https://test') as c:
        h={'Authorization':'Bearer '+token};o={'Authorization':'Bearer '+other}
        ids={'symbols':['stock:NASDAQ:AAPL']}
        assert c.get('/v1/catalog',headers=o).json()['instruments']==[]
        assert c.post('/v1/quotes',headers=o,json=ids).status_code==403
        assert not calls
        catalog=c.get('/v1/catalog',headers=h).json()['instruments']
        assert len(catalog)==1 and catalog[0]['provider']=='alpaca' and catalog[0]['market']=='US'
        result=c.post('/v1/quotes',headers=h,json=ids)
        q=result.json()['quotes'][0]
        assert q['price']==100 and q['change']==25 and q['source']=='Alpaca · IEX'
        assert q['basis']=='last' and q['currency']=='USD' and q['delaySeconds']==0
        assert 'fixture' not in result.text
        assert c.post('/v1/quotes',headers=h,json=ids).json()['quotes']==[q]
        assert len(calls)==3
        store.db.execute("UPDATE runtime_cache SET updated=? WHERE key LIKE ?",(now()-100,'alpaca:%'))
        state['fail']=True
        assert c.post('/v1/quotes',headers=h,json=ids).json()['quotes']==[q]
        assert c.post('/v1/quotes',headers=h,json={'symbols':['stock:NASDAQ:UNKNOWN']}).status_code==422
        # Warm caches never grant another installation access.
        assert c.post('/v1/quotes',headers=o,json=ids).status_code==403
        assert c.get('/v1/catalog',headers=o).json()['instruments']==[]


def test_reject_non_iex_trades_and_disable_incomplete_config(tmp_path):
    settings,store,hub,token,other,calls,state=setup(tmp_path)
    state['exchange']='N'
    with TestClient(create_app(settings,injected_store=store,injected_hub=hub,run_workers=False),base_url='https://test') as c:
        r=c.post('/v1/quotes',headers={'Authorization':'Bearer '+token},json={'symbols':['stock:NASDAQ:AAPL']})
        assert r.status_code==200 and r.json()['quotes']==[]
    assert not replace(settings,alpaca_personal_user='').alpaca_enabled
    assert not replace(settings,alpaca_secret='').alpaca_enabled


def test_bad_future_prices_and_same_day_reference_are_handled(tmp_path):
    from nosce.alpaca import snapshot_quote
    from nosce.models import Instrument
    import pytest
    item=Instrument(id='stock:NASDAQ:AAPL',symbol='AAPL',name='Apple',market='US',currency='USD',provider='alpaca',provider_symbol='AAPL')
    stamp=(datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()
    payload={'latestTrade':{'p':100,'x':'V','t':stamp},'prevDailyBar':{'c':80,'t':stamp}}
    assert snapshot_quote(item,payload,False).change is None
    assert snapshot_quote(item,payload,False).market_state=='closed'
    payload['latestTrade']['t']=(datetime.now(timezone.utc)+timedelta(days=1)).isoformat()
    with pytest.raises(ValueError):snapshot_quote(item,payload,True)
