import asyncio
import time
from contextlib import asynccontextmanager
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient
from nosce.admin import password_hash
from nosce.apple_services import Billing
from nosce.database import Store
from nosce.main import create_app
from nosce.models import now
from nosce.postgres import PostgresDB
from test_commerce import cfg, tx


def test_full_user_page_has_bounded_queries_and_preserves_entitlements(tmp_path):
    settings=cfg(tmp_path,admin_password_hash=password_hash('test-only-password-long'))
    store=Store(':memory:',settings.token_key);billing=Billing(settings,store)
    owners=[]
    for n in range(50):
        install,_=store.register();user=store.user(install)['id'];owners.append(user)
        billing.save(tx(user,transactionId='tx-'+str(n),originalTransactionId='original-'+str(n)))
    # Grace overrides expiry, but a revoked latest renewal must never revive an older order.
    store.db.execute('INSERT INTO renewals VALUES(?,?,?,?,?)',('original-0',1,now()+200000,1,now()))
    billing.save(tx(owners[1],transactionId='revoked-latest',originalTransactionId='original-1',
                    purchaseDate=int(now()*1000)+1000,signedDate=int(now()*1000)+1000,revocationDate=int(now()*1000)))
    expected={user:billing.entitlement(user) for user in owners}
    queries=[];store.db.set_trace_callback(queries.append)
    with TestClient(create_app(settings,injected_store=store,run_workers=False),base_url='https://api.test') as client:
        csrf=client.post('/admin/api/login',json={'username':'admin','password':'test-only-password-long'}).json()['csrf']
        queries.clear();response=client.get('/admin/api/users');assert response.status_code==200
        # Session check + atomic session limiter + one user-page query, independent of user count.
        assert len(queries)==3
        users=response.json()['items'];assert len(users)==50
        assert all(value['expiresAt']==expected[value['id']] for value in users)
        grace=next(value for value in users if value['id']==owners[0]);assert grace['billingRetry'] and grace['autoRenew']==1
        queries.clear();overview=client.get('/admin/api/overview');assert overview.status_code==200 and len(queries)==5
        assert overview.json()['users']==50 and overview.json()['paying']==49
        queries.clear();assert client.post('/admin/api/logout',headers={'X-CSRF-Token':csrf}).status_code==200
        assert len(queries)==2 and all('limits' not in query for query in queries)
        assert client.get('/admin/api/session').status_code==401


@pytest.mark.asyncio
async def test_postgres_connect_does_not_block_other_requests(monkeypatch):
    db=PostgresDB('unused-in-test')
    class Connection:
        closed=False
        def close(self):self.closed=True
    connection=Connection()
    def slow_connect():time.sleep(.15);return connection
    monkeypatch.setattr(db,'connect',slow_connect)
    progress=[];metrics={}
    async def independent_request():
        await asyncio.sleep(.02);progress.append('responsive')
    async def database_request():
        async with db.request_session(metrics):
            assert progress==['responsive']
            assert db.current.get() is connection
    await asyncio.gather(database_request(),independent_request())
    assert connection.closed and db.current.get() is None and metrics['connect_ms']>=100


def test_admin_atomic_rate_limit_still_enforced(tmp_path):
    store=Store(':memory:',cfg(tmp_path).token_key)
    assert store.admin_limit('admin:test',2)
    assert store.admin_limit('admin:test',2)
    assert not store.admin_limit('admin:test',2)
    store.db.execute('UPDATE limits SET bucket=-1')
    assert store.admin_limit('admin:test',2)
    store.close()

from test_vercel import postgres_settings


def test_postgres_admin_queries_and_public_routes(postgres_settings,monkeypatch):
    settings=postgres_settings;store=Store(settings.database,settings.token_key);billing=Billing(settings,store)
    users=[]
    for n in range(3):
        install,_=store.register();user=store.user(install)['id'];users.append(user)
        billing.save(tx(user,transactionId='pg-tx-'+str(n),originalTransactionId='pg-original-'+str(n)))
    expected={user:billing.entitlement(user) for user in users}
    with TestClient(create_app(settings,injected_store=store,run_workers=False),base_url='https://api.test') as client:
        # Public routes must work even while database connections are unavailable.
        connect=store.db.connect
        def unavailable():raise AssertionError('Public route opened a database connection')
        monkeypatch.setattr(store.db,'connect',unavailable)
        for path in ['/admin','/healthz','/admin/api/config']:
            result=client.get(path);assert result.status_code==200 and 'queries;desc="0"' in result.headers['server-timing']
        monkeypatch.setattr(store.db,'connect',connect)
        csrf=client.post('/admin/api/login',json={'username':'admin','password':'test-only-password-long'}).json()['csrf']
        response=client.get('/admin/api/users');assert response.status_code==200
        assert 'queries;desc="3"' in response.headers['server-timing']
        assert all(value['expiresAt']==expected[value['id']] for value in response.json()['items'])
        result=client.get('/admin/api/overview');assert result.status_code==200 and 'queries;desc="5"' in result.headers['server-timing']
        result=client.post('/admin/api/logout',headers={'X-CSRF-Token':csrf});assert result.status_code==200 and 'queries;desc="2"' in result.headers['server-timing']
    assert store.db.execute('SELECT version FROM schema_version WHERE version=2').fetchone()
