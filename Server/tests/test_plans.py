import pytest
from dataclasses import replace
from types import SimpleNamespace
from fastapi.testclient import TestClient
from nosce.plans import plan_catalog,installation_access,enforce_count
from nosce.models import now
from nosce.database import Store
from nosce.main import create_app
from nosce.apple_services import Billing
from nosce.providers import MarketHub,hyperliquid_quote
from nosce.apns import push_due
from test_commerce import cfg,tx,Verifier
from test_service import item,session,Sender


def test_verified_entitlements_limits_expiry_refund_and_grace(tmp_path):
    config=cfg(tmp_path);store=Store(':memory:',config.token_key);owner,_=store.register()
    billing=Billing(config,store);user=store.user(owner)['id']
    free=installation_access(store,owner)
    assert (free['plan'],free['watchlistLimit'],free['islandLimit'])==('free',3,1)
    enforce_count(store,owner,list('abc'),'watchlist')
    with pytest.raises(Exception):enforce_count(store,owner,list('abcd'),'watchlist')
    with pytest.raises(Exception):enforce_count(store,owner,list('ab'),'widget')
    with pytest.raises(Exception) as error:enforce_count(store,owner,['a','b'],'island')
    assert error.value.status_code==403
    billing.save(tx(user))
    pro=installation_access(store,owner)
    assert pro['plan']=='pro' and pro['widgetFamilies']==['small','medium','large']
    assert billing.profile(owner)['access']==pro
    enforce_count(store,owner,list('abcdefgh'),'island')
    assert installation_access(store,owner,timestamp=pro['expiresAt']+1)['plan']=='free'
    # Cancelling renewal does not remove the already-paid period; verified grace is honoured.
    store.db.execute('INSERT INTO renewals VALUES(?,?,?,?,?)',('1000',0,pro['expiresAt']+3600,0,now()))
    assert installation_access(store,owner,timestamp=pro['expiresAt']+1)['plan']=='pro'
    billing.save(tx(user,revocationDate=int(now()*1000),signedDate=int(now()*1000)+1000))
    assert installation_access(store,owner)['plan']=='free'


def test_server_rejects_free_multi_asset_activity_and_public_contract_matches(tmp_path):
    config=replace(cfg(tmp_path),apns_team_id='fixture',apns_key_id='fixture',apns_key_pem='fixture-not-a-key')
    store=Store(':memory:',config.token_key);owner,bearer=store.register();hub=MarketHub(config,store)
    hub.catalog={key:item(key) for key in ['hl:BTC','hl:ETH']}
    sender=Sender();app=create_app(config,injected_store=store,injected_hub=hub,injected_sender=sender,run_workers=False)
    with TestClient(app) as client:
        headers={'Authorization':'Bearer '+bearer};value=session(symbols=['hl:BTC','hl:ETH']).model_dump()
        denied=client.post('/v1/sessions',headers=headers,json=value)
        assert denied.status_code==403 and denied.json()['detail']['code']=='pro_required'
        assert not store.sessions()
        assert client.get('/api/public/plans').json()==plan_catalog()
        assert client.get('/api/public/plans').headers['Server-Timing'].endswith('queries;desc="0"')
        Billing(config,store).save(tx(store.user(owner)['id']))
        assert client.post('/v1/sessions',headers=headers,json=value).status_code==200
        single=client.post('/v1/sessions',headers=headers,json=dict(value,symbols=['hl:BTC']))
        assert single.status_code==200


@pytest.mark.asyncio
async def test_worker_rechecks_expired_pro_without_forging_quote_time(tmp_path):
    config=cfg(tmp_path);store=Store(':memory:',config.token_key);owner,_=store.register();billing=Billing(config,store)
    stamp=now();expiry=stamp+2;billing.save(tx(store.user(owner)['id'],expiresDate=int(expiry*1000)))
    store.upsert(owner,session(symbols=['hl:BTC','hl:ETH']),100,64)
    quotes={key:hyperliquid_quote(item(key),{'markPx':'100','prevDayPx':'90'},stamp) for key in ['hl:BTC','hl:ETH']}
    sender=Sender();hub=SimpleNamespace(quotes=quotes)
    await push_due(store,hub,sender,config,stamp)
    assert len(sender.calls[-1][1]['quotes'])==2
    await push_due(store,hub,sender,config,stamp+61)
    assert [quote['id'] for quote in sender.calls[-1][1]['quotes']]==['hl:BTC']
    assert sender.calls[-1][1]['page']==0
    assert sender.calls[-1][1]['quotes'][0]['updatedAt']==quotes['hl:BTC'].wire()['updatedAt']


def test_widget_entitlement_capability_is_read_only_and_tracks_refunds(tmp_path):
    config=cfg(tmp_path);store=Store(':memory:',config.token_key);owner,bearer=store.register()
    app=create_app(config,injected_store=store,run_workers=False)
    with TestClient(app) as client:
        headers={'Authorization':'Bearer '+bearer}
        assert client.post('/v1/widget-entitlement-access').status_code==401
        grant=client.post('/v1/widget-entitlement-access',headers=headers)
        assert grant.status_code==200 and grant.json()['token']!=bearer
        capability={'Authorization':'Bearer '+grant.json()['token']}
        assert client.get('/v1/widget/entitlement',headers=headers).status_code==401
        assert client.get('/v1/me',headers=capability).status_code==401
        assert client.post('/v1/widget-entitlement-access',headers=capability).status_code==401
        assert client.get('/v1/widget/entitlement',headers=capability).json()=={'proExpiresAt':None}
        billing=Billing(config,store);user=store.user(owner)['id'];billing.save(tx(user))
        assert client.get('/v1/widget/entitlement',headers=capability).json()['proExpiresAt']>now()
        billing.save(tx(user,revocationDate=int(now()*1000),signedDate=int(now()*1000)+1000))
        assert client.get('/v1/widget/entitlement',headers=capability).json()=={'proExpiresAt':None}
        client.delete('/v1/installation',headers=headers)
        assert client.get('/v1/widget/entitlement',headers=capability).status_code==401
