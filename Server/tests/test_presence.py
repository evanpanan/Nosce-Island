from dataclasses import replace
from fastapi.testclient import TestClient
from nosce.admin import password_hash
from nosce.database import Store
from nosce.main import create_app
from nosce.models import now
from test_service import settings


def test_presence_is_authenticated_expiring_and_separate_from_background_sessions(settings):
    cfg=replace(settings,admin_password_hash=password_hash('test-only-admin-password'))
    store=Store(':memory:',cfg.token_key)
    first,token=store.register()
    second,other=store.register()
    # Simulate two installations linked to one anonymous App Store identity.
    user=store.user(first)['id']
    store.db.execute('UPDATE installs SET user_id=? WHERE id=?',(user,second))
    with TestClient(create_app(cfg,injected_store=store,run_workers=False),base_url='https://api.test') as client:
        assert client.post('/v1/presence').status_code==401
        assert client.get('/admin/api/overview').status_code==401
        assert client.post('/admin/api/login',json={'username':'admin','password':'test-only-admin-password'}).status_code==200
        assert client.get('/admin/api/overview').json()['onlineUsers']==0
        for bearer in (token,other):
            headers={'Authorization':'Bearer '+bearer}
            assert client.post('/v1/presence',headers=headers).status_code==200
            assert client.post('/v1/presence',headers=headers).status_code==200
        data=client.get('/admin/api/overview').json()
        assert (data['onlineUsers'],data['onlineDevices'],data['sessions'])==(1,2,0)
        store.db.execute('UPDATE runtime_cache SET updated=? WHERE key LIKE ?',(now()-91,'presence:%'))
        # Normal authenticated requests do not renew foreground presence.
        client.get('/v1/catalog',headers={'Authorization':'Bearer '+token})
        assert client.get('/admin/api/overview').json()['onlineDevices']==0
        assert client.post('/v1/presence',headers={'Authorization':'Bearer '+token}).status_code==200
        assert client.get('/admin/api/overview').json()['onlineDevices']==1
