from types import SimpleNamespace
import pytest
from fastapi.testclient import TestClient
from nosce.apple_services import Billing
from nosce.database import Store
from nosce.main import create_app
from nosce.providers import MarketHub
from test_commerce import cfg, tx, Verifier


class StoreVerifier(Verifier):
    def __init__(self, identity='app-123', **kw):
        super().__init__(None)
        self.identity = identity
        self.values = kw
    async def app_transaction(self, signed):
        if signed != 'verified-app-transaction':
            raise ValueError('Bad signature')
        return SimpleNamespace(bundleId='com.cooper.nosceisland', receiptType='Sandbox',
                               appTransactionId=self.identity, **self.values)


@pytest.mark.asyncio
async def test_no_login_identity_restores_same_user_across_devices(tmp_path):
    settings=cfg(tmp_path);store=Store(':memory:',settings.token_key)
    first,_=store.register();second,_=store.register()
    verifier=StoreVerifier();billing=Billing(settings,store,verifier)
    first_profile=await billing.link_store(first,'verified-app-transaction')
    owner=first_profile['userId']
    assert first_profile['storeLinked'] and not first_profile['signedIn']
    assert store.user(first)['email'] is None
    verifier.value=tx(owner,appTransactionId='app-123')
    await billing.submit(first,'test-only-signed-payload')
    restored=await billing.link_store(second,'verified-app-transaction')
    assert restored['userId']==owner and restored['pro']
    assert store.user(second)['apple_hash'] is None
    assert 'app-123' not in store.user(second)['app_store_hash']


@pytest.mark.asyncio
async def test_no_login_rejects_copied_purchase_from_other_identity(tmp_path):
    settings=cfg(tmp_path);store=Store(':memory:',settings.token_key)
    first,_=store.register();second,_=store.register()
    verifier=StoreVerifier();billing=Billing(settings,store,verifier)
    await billing.link_store(first,'verified-app-transaction')
    verifier.identity='another-apple-account'
    await billing.link_store(second,'verified-app-transaction')
    # Even an appAccountToken matching the second user cannot pass the independent identity check.
    verifier.value=tx(store.user(second)['id'],appTransactionId='app-123')
    with pytest.raises(PermissionError):
        await billing.submit(second,'test-only-signed-payload')
    assert not billing.profile(second)['pro']


@pytest.mark.asyncio
async def test_invalid_app_transaction_cannot_link_installation(tmp_path):
    settings=cfg(tmp_path);store=Store(':memory:',settings.token_key)
    install,_=store.register();verifier=StoreVerifier();billing=Billing(settings,store,verifier)
    for identity in ['',None]:
        verifier.identity=identity
        with pytest.raises(ValueError):
            await billing.link_store(install,'verified-app-transaction')
    with pytest.raises(ValueError):
        await billing.link_store(install,'unsigned-app-transaction')
    assert not billing.profile(install)['storeLinked']


def test_identity_route_is_automatic_authenticated_and_no_signin_requirement(tmp_path):
    settings=cfg(tmp_path,sales_enabled=True,privacy_url='https://example.com/privacy',terms_url='https://example.com/terms')
    store=Store(':memory:',settings.token_key);hub=MarketHub(settings,store);verifier=StoreVerifier()
    billing=Billing(settings,store,verifier)
    app=create_app(settings,injected_store=store,injected_hub=hub,injected_billing=billing,run_workers=False)
    with TestClient(app,base_url='https://api.test') as client:
        bearer=client.post('/v1/installations').json()['token'];headers={'Authorization':'Bearer '+bearer}
        assert client.post('/v1/app-store/identity',json={'signed_app_transaction':'verified-app-transaction'}).status_code==401
        result=client.post('/v1/app-store/identity',headers=headers,json={'signed_app_transaction':'verified-app-transaction'})
        assert result.status_code==200
        assert result.json()['storeLinked'] and result.json()['purchaseEnabled']
        assert not result.json()['signedIn']
