import json
from dataclasses import replace
from types import SimpleNamespace
import pytest
from pydantic import ValidationError
from fastapi.testclient import TestClient
from nosce.database import Store
from nosce.models import SessionInput, now
from nosce.providers import hyperliquid_quote, MarketHub
from nosce.apns import push_due
from nosce.main import create_app
from nosce.admin import password_hash,totp
from test_service import settings,item,session,Sender


def test_multi_watch_capacity_and_duplicates():
    keys=['hl:asset'+str(i) for i in range(8)]
    assert len(session(symbols=keys).symbols)==8
    for invalid in [keys+['hl:ninth'],['hl:BTC','hl:BTC'],[]]:
        with pytest.raises(ValidationError):
            SessionInput(activity_id='activity',push_token='a'*64,environment='production',symbols=invalid)


@pytest.mark.asyncio
async def test_all_eight_assets_rotate_without_losing_order_or_exceeding_payload(settings):
    stamp=now();keys=['hl:asset'+str(i) for i in range(8)]
    store=Store(':memory:',settings.token_key);owner,_=store.register()
    store.upsert(owner,session(symbols=keys),100,64)
    quotes={key:hyperliquid_quote(item(key),{'markPx':'100','prevDayPx':'90'},stamp) for key in keys}
    sender=Sender();hub=SimpleNamespace(quotes=quotes)
    for n in range(5):
        await push_due(store,hub,sender,settings,stamp+n*settings.push_interval)
    assert len(sender.calls)==5
    seen=set()
    for _,state,stale,_,_ in sender.calls:
        assert [q['id'] for q in state['quotes']]==keys
        page=state['page'];seen.update(q['id'] for q in state['quotes'][page*2:page*2+2])
        assert len(json.dumps({'aps':{'content-state':state,'timestamp':int(stamp),'stale-date':int(stale)}}).encode())<4096
    assert seen==set(keys)


@pytest.mark.asyncio
async def test_one_stale_asset_does_not_freeze_healthy_assets_or_forge_time(settings):
    stamp=now();keys=['hl:BTC','hl:ETH','hl:SOL']
    store=Store(':memory:',settings.token_key);owner,_=store.register();store.upsert(owner,session(symbols=keys),100,64)
    quotes={key:hyperliquid_quote(item(key),{'markPx':'100','prevDayPx':'90'},stamp if key!='hl:ETH' else stamp-1000) for key in keys}
    sender=Sender();await push_due(store,SimpleNamespace(quotes=quotes),sender,settings,stamp)
    assert len(sender.calls)==1
    state=sender.calls[0][1]
    assert state['quotes'][1]['updatedAt']==quotes['hl:ETH'].wire()['updatedAt']
    assert sender.calls[0][2]>stamp
    await push_due(store,SimpleNamespace(quotes=quotes),sender,settings,stamp+1000)
    assert len(sender.calls)==1  # Entire feed stale: no artificial refresh or rotation.


def test_admin_activity_list_is_private_and_does_not_return_push_secrets(settings):
    settings=replace(settings,admin_password_hash=password_hash('test-admin-password-only'),admin_totp_secret='JBSWY3DPEHPK3PXP')
    store=Store(':memory:',settings.token_key);owner,bearer=store.register()
    store.upsert(owner,session(symbols=['hl:BTC','hl:ETH','hl:SOL']),100,64)
    app=create_app(settings,injected_store=store,run_workers=False)
    with TestClient(app,base_url='https://api.test') as client:
        assert client.get('/admin/api/activities').status_code==401
        assert client.get('/admin/api/activities',headers={'Authorization':'Bearer '+bearer}).status_code==401
        code=totp(settings.admin_totp_secret,int(now()/30))
        assert client.post('/admin/api/login',json={'username':'admin','password':'test-admin-password-only','code':code}).status_code==200
        data=client.get('/admin/api/activities').json()
        assert data['items'][0]['groupCount']==2
        assert data['items'][0]['symbols']==['hl:BTC','hl:ETH','hl:SOL']
        assert 'a'*64 not in json.dumps(data)
        assert client.get('/admin/api/activities?search=not-present').json()['items']==[]
