from dataclasses import replace
from fastapi.testclient import TestClient
from nosce.main import create_app
from nosce.models import now
from test_alpaca import setup


def test_widget_grant_is_read_only_scoped_revocable_and_not_foreground_presence(tmp_path):
    settings,store,hub,token,other,calls,state=setup(tmp_path)
    from nosce.admin import password_hash
    settings=replace(settings,admin_password_hash=password_hash('widget-admin-fixture-password'))
    app=create_app(settings,injected_store=store,injected_hub=hub,run_workers=False)
    ids={'symbols':['stock:NASDAQ:AAPL']}
    with TestClient(app,base_url='https://test') as c:
        h={'Authorization':'Bearer '+token}
        assert c.post('/v1/widget-access',json=ids).status_code==401
        assert c.post('/v1/widget-access',headers={'Authorization':'Bearer '+other},json=ids).status_code==403
        r=c.post('/v1/widget-access',headers=h,json=ids);assert r.status_code==200
        grant=r.json();assert grant['expiresAt']>now()+6*86400
        assert 'fixture-secret' not in r.text and token not in r.text
        w={'Authorization':'Bearer '+grant['token']}
        result=c.post('/v1/widget/quotes',headers=w,json=ids)
        assert result.status_code==200 and result.json()['quotes'][0]['source']=='Alpaca · IEX'
        assert c.post('/v1/quotes',headers=w,json=ids).status_code==401
        assert c.post('/v1/presence',headers=w).status_code==401
        assert c.post('/v1/widget/quotes',headers=w,json={'symbols':['stock:NYSE:IBM']}).status_code==403
        assert c.get('/admin/api/services/config',headers=w).status_code==401
        install=grant['token'].split('.')[0]
        payload,_=store.get_cache('widget-access:'+install)
        assert grant['token'] not in str(payload)
        assert store.get_cache('presence:'+install)[0] is None
        # New issuance revokes the previous capability immediately.
        replacement=c.post('/v1/widget-access',headers=h,json=ids).json()
        assert c.post('/v1/widget/quotes',headers=w,json=ids).status_code==401
        latest={'Authorization':'Bearer '+replacement['token']}
        assert c.post('/v1/widget/quotes',headers=latest,json=ids).status_code==200
        assert c.delete('/v1/installation',headers=h).status_code==204
        assert c.post('/v1/widget/quotes',headers=latest,json=ids).status_code==403


def test_widget_access_expires_and_configuration_revocation_is_enforced(tmp_path):
    settings,store,hub,token,other,calls,state=setup(tmp_path)
    app=create_app(settings,injected_store=store,injected_hub=hub,run_workers=False)
    ids={'symbols':['stock:NASDAQ:AAPL']}
    with TestClient(app,base_url='https://test') as c:
        r=c.post('/v1/widget-access',headers={'Authorization':'Bearer '+token},json=ids).json()
        install=r['token'].split('.')[0];w={'Authorization':'Bearer '+r['token']}
        app.state.runtime.base=replace(settings,alpaca_personal_user='revoked-user')
        assert c.post('/v1/widget/quotes',headers=w,json=ids).status_code==403
        app.state.runtime.base=settings
        record,_=store.get_cache('widget-access:'+install)
        record['expires']=now()-1;store.put_cache('widget-access:'+install,record)
        assert c.post('/v1/widget/quotes',headers=w,json=ids).status_code==401
