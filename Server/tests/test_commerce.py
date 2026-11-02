import asyncio
import json
import time
from dataclasses import replace
from types import SimpleNamespace
import pytest
from fastapi.testclient import TestClient
from nosce.config import Settings
from nosce.database import Store
from nosce.providers import MarketHub
from nosce.binance_feed import instrument, mark_quote
from nosce.apple_services import Billing, AppleIdentity
from nosce.admin import password_hash, password_valid, totp
from nosce.main import create_app
from nosce.models import now


def cfg(tmp_path, **kw):
    return replace(Settings(database=str(tmp_path/"state.sqlite"),token_key="03"*32,
        app_store_products="pro.monthly",app_store_environment="Sandbox"),**kw)


def tx(user, **values):
    data = dict(appAccountToken=user,productId="pro.monthly",bundleId="com.cooper.nosceisland",environment="Sandbox",
        type="Auto-Renewable Subscription",transactionId="1001",originalTransactionId="1000",
        signedDate=int(now()*1000),purchaseDate=int(now()*1000)-1000,expiresDate=int(now()*1000)+86400000,
        revocationDate=None,isUpgraded=False,price=1990,currency="USD")
    return SimpleNamespace(**(data|values))


class Verifier:
    enabled = True
    def __init__(self, transaction):
        self.value = transaction
        self.called = []
    async def fresh_transaction(self, signed):
        self.called.append(signed)
        if signed != "test-only-signed-payload":
            raise ValueError("Invalid signature")
        return self.value
    async def transaction(self, signed):
        return await self.fresh_transaction(signed)
    async def notification(self, signed):
        if signed != "test-only-notification":
            raise ValueError("Invalid signature")
        return SimpleNamespace(notificationUUID="event-1",notificationType="DID_RENEW",data=SimpleNamespace(signedTransactionInfo="test-only-signed-payload"))


def test_anonymous_identity_persists_and_user_data_is_separate(tmp_path):
    settings = cfg(tmp_path)
    store = Store(settings.database,settings.token_key)
    install,bearer = store.register(); user = store.user(install)["id"]
    store.close();store = Store(settings.database,settings.token_key)
    assert store.user(store.authenticate(bearer))["id"] == user
    other,_ = store.register()
    assert store.user(other)["id"] != user
    store.close()


def test_migrates_existing_v03_database(tmp_path):
    import sqlite3
    settings = cfg(tmp_path)
    old = sqlite3.connect(settings.database)
    old.execute("CREATE TABLE installs(id TEXT PRIMARY KEY,token_hash TEXT UNIQUE NOT NULL,created REAL NOT NULL)")
    old.execute("INSERT INTO installs VALUES('existing','abc',?)",(now(),));old.commit();old.close()
    store = Store(settings.database,settings.token_key)
    assert store.user("existing")["id"]
    store.close()


@pytest.mark.asyncio
async def test_verified_purchase_is_bound_idempotent_and_revocation_wins(tmp_path):
    settings=cfg(tmp_path);store=Store(":memory:",settings.token_key)
    install,_=store.register();user=store.user(install)["id"]
    store.db.execute("UPDATE users SET apple_hash='test-subject' WHERE id=?",(user,))
    valid=tx(user); verifier=Verifier(valid); billing=Billing(settings,store,verifier)
    await billing.submit(install,"test-only-signed-payload")
    await billing.submit(install,"test-only-signed-payload")
    assert billing.profile(install)["pro"] is True
    assert store.db.execute("SELECT count(*) FROM orders").fetchone()[0]==1
    refunded=tx(user,signedDate=valid.signedDate+1000,revocationDate=valid.signedDate)
    billing.save(refunded)
    assert not billing.profile(install)["pro"]
    billing.save(valid)  # Out-of-order pre-refund event must not re-enable Pro.
    assert not billing.profile(install)["pro"]
    other,_=store.register();store.db.execute("UPDATE users SET apple_hash='other' WHERE id=?",(store.user(other)["id"],))
    with pytest.raises(PermissionError):
        await billing.submit(other,"test-only-signed-payload")
    assert verifier.called


@pytest.mark.asyncio
async def test_notification_duplicates_and_unsigned_purchase_are_rejected(tmp_path):
    settings=cfg(tmp_path);store=Store(":memory:",settings.token_key)
    install,_=store.register();user=store.user(install)["id"]
    store.db.execute("UPDATE users SET apple_hash='a' WHERE id=?",(user,))
    billing=Billing(settings,store,Verifier(tx(user)))
    with pytest.raises(ValueError):
        await billing.submit(install,"a-fake-transaction")
    assert store.db.execute("SELECT count(*) FROM orders").fetchone()[0]==0
    await billing.notify("test-only-notification");await billing.notify("test-only-notification")
    assert store.db.execute("SELECT count(*) FROM apple_events").fetchone()[0]==1
    assert store.db.execute("SELECT count(*) FROM orders").fetchone()[0]==1


@pytest.mark.parametrize("field,value",[("bundleId","other.app"),("environment","Production"),("productId","not-approved"),("type","Consumable")])
def test_wrong_store_transaction_properties_fail_closed(tmp_path,field,value):
    settings=cfg(tmp_path);store=Store(":memory:",settings.token_key);install,_=store.register()
    billing=Billing(settings,store,Verifier(None))
    with pytest.raises(ValueError):
        billing.save(tx(store.user(install)["id"],**{field:value}))
    assert store.db.execute("SELECT count(*) FROM orders").fetchone()[0]==0


def test_sales_disabled_without_real_configuration(tmp_path):
    settings=cfg(tmp_path);store=Store(":memory:",settings.token_key);install,_=store.register()
    billing=Billing(settings,store)
    profile=billing.profile(install)
    assert not profile["purchaseEnabled"] and not billing.verifier.enabled and profile["productIds"]==["pro.monthly"]  # configured IDs stay available for restoring existing purchases


def make_app(settings):
    store=Store(":memory:",settings.token_key)
    hub=MarketHub(settings,store)
    return create_app(settings,store,hub,run_workers=False)


def test_admin_auth_cookie_csrf_and_no_secret_exposure(tmp_path):
    secret="JBSWY3DPEHPK3PXP"
    settings=cfg(tmp_path,admin_password_hash=password_hash("test-only-password-strong"),admin_totp_secret=secret)
    app=make_app(settings)
    with TestClient(app,base_url="https://nosce.test") as client:
        assert client.get("/admin/api/users").status_code==401
        anon=client.post("/v1/installations").json()
        assert client.get("/admin/api/orders",headers={"Authorization":"Bearer "+anon["token"]}).status_code==401
        page=client.get("/admin")
        assert "nonce-" in page.headers["content-security-policy"]
        response=client.post("/admin/api/login",json={"username":"admin","password":"test-only-password-strong","code":totp(secret,int(now()/30))})
        assert response.status_code==200
        assert "httponly" in response.headers["set-cookie"].lower()
        assert "secure" in response.headers["set-cookie"].lower()
        csrf=response.json()["csrf"]
        users=client.get("/admin/api/users")
        assert users.status_code==200 and len(users.json()["items"])==1
        body=users.text
        assert anon["token"] not in body and "token_hash" not in body and "refresh" not in body
        assert client.post("/admin/api/logout").status_code==403
        assert client.post("/admin/api/logout",headers={"X-CSRF-Token":csrf}).status_code==200
        assert client.get("/admin/api/overview").status_code==401
        # An already-used TOTP cannot mint a second administrator session.
        assert client.post("/admin/api/login",json={"username":"admin","password":"test-only-password-strong","code":totp(secret,int(now()/30))}).status_code==401


def test_admin_disabled_and_purchase_spoof_has_no_effect(tmp_path):
    app=make_app(cfg(tmp_path))
    with TestClient(app) as client:
        assert client.get("/admin/api/overview").status_code==503
        installed=client.post("/v1/installations").json()
        auth={"Authorization":"Bearer "+installed["token"]}
        assert client.get("/v1/me",headers=auth).json()["pro"] is False
        assert client.post("/v1/purchases",json={"signed_transaction":"unsigned-payload-value"},headers=auth).status_code==503
        assert app.state.store.db.execute("SELECT count(*) FROM orders").fetchone()[0]==0
        assert client.post("/v1/app-store/notifications",json={"signedPayload":"fake-notification-value"}).status_code==503


def test_binance_currency_contract_identity_and_event_time():
    def asset(symbol,category,base):
        return {"symbol":symbol,"baseAsset":base,"quoteAsset":"USDT","marginAsset":"USDT","status":"TRADING","contractType":"PERPETUAL","underlyingType":category}
    hk=instrument(asset("HK0700USDT","HK_EQUITY","HK0700"))
    usd=instrument(asset("TENCENTUSDT","HK_EQUITY","TENCENT"))
    nvda=instrument(asset("NVDAUSDT","EQUITY","NVDA"))
    assert hk.currency=="HKD" and hk.settlement_currency=="USDT"
    assert usd.currency=="USDT" and hk.id != usd.id
    assert nvda.market=="Contracts" and nvda.region=="US"
    event={"s":"NVDAUSDT","p":"100.25","E":int(now()*1000)}
    q=mark_quote(nvda,event)
    assert q.price==100.25 and q.basis=="mark" and q.change is None
    assert q.updated_at==event["E"]/1000
    with pytest.raises(ValueError):mark_quote(nvda,dict(event,p="NaN"))
    with pytest.raises(ValueError):mark_quote(nvda,dict(event,s="AAPLUSDT"))
    assert instrument(dict(asset("NVDAUSDT","EQUITY","NVDA"),status="PENDING_TRADING")) is None


def test_admin_password_and_rfc_totp():
    encoded=password_hash("unit-test-only-password")
    assert password_valid("unit-test-only-password",encoded)
    assert not password_valid("wrong-password",encoded)
    # RFC 6238 SHA1 vector at unix 59 seconds, represented with six digits.
    assert totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",1)=="287082"


@pytest.mark.asyncio
async def test_apple_identity_nonce_rotation_and_cross_device_link(tmp_path):
    import hashlib,httpx,jwt
    from urllib.parse import parse_qs
    from cryptography.hazmat.primitives.asymmetric import ec,rsa
    from cryptography.hazmat.primitives import serialization
    private=ec.generate_private_key(ec.SECP256R1())
    keyfile=tmp_path/"unit-signin.p8"
    keyfile.write_bytes(private.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    settings=cfg(tmp_path,apple_signin_team="UNITTEST00",apple_signin_key_id="UNITKEY001",apple_signin_key_file=str(keyfile))
    store=Store(":memory:",settings.token_key)
    identity=AppleIdentity(settings,store)
    signing=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    identity.keys={"unit":signing.public_key()};identity.keys_at=now()
    nonces={}
    async def handler(request):
        values=parse_qs(request.content.decode());code=values["code"][0]
        claims=jwt.decode(values["client_secret"][0],private.public_key(),algorithms=["ES256"],audience="https://appleid.apple.com")
        assert claims["sub"]==settings.bundle_id
        token=jwt.encode({"iss":"https://appleid.apple.com","sub":"test-same-apple-account","aud":settings.bundle_id,
            "iat":int(now()),"exp":int(now()+300),"nonce":nonces[code],"email":"test@privaterelay.appleid.com","email_verified":"true"},
            signing,algorithm="RS256",headers={"kid":"unit"})
        return httpx.Response(200,json={"id_token":token,"refresh_token":"test-only-refresh"})
    await identity.client.aclose();identity.client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
    first,old=store.register();challenge=identity.challenge(first)
    nonces["first"]=hashlib.sha256(challenge["nonce"].encode()).hexdigest()
    rotated=await identity.login(first,challenge["id"],"first")
    assert store.authenticate(old) is None and store.authenticate(rotated)==first
    owner=store.user(first)["id"]
    second,_=store.register();challenge=identity.challenge(second)
    nonces["second"]=hashlib.sha256(challenge["nonce"].encode()).hexdigest()
    await identity.login(second,challenge["id"],"second")
    assert store.user(second)["id"]==owner
    third,_=store.register();challenge=identity.challenge(third);nonces["wrong"]="wrong-nonce"
    with pytest.raises(ValueError):await identity.login(third,challenge["id"],"wrong")
    assert store.user(third)["apple_hash"] is None
    with pytest.raises(ValueError):await identity.login(third,challenge["id"],"wrong")
    await identity.close();store.close()


def test_cancelled_renewal_preserves_access_and_verified_grace_expires(tmp_path):
    settings=cfg(tmp_path);store=Store(":memory:",settings.token_key)
    install,_=store.register();user=store.user(install)["id"]
    billing=Billing(settings,store,Verifier(None));value=tx(user)
    billing.save(value)
    renewal=SimpleNamespace(originalTransactionId=value.originalTransactionId,signedDate=value.signedDate,
        autoRenewStatus=0,gracePeriodExpiresDate=None,isInBillingRetryPeriod=False)
    billing.save_renewal(renewal)
    assert billing.profile(install)["pro"] is True
    assert billing.profile(install)["autoRenew"]==0
    expired=tx(user,purchaseDate=int(now()-200)*1000,expiresDate=int(now()-100)*1000,signedDate=value.signedDate+1000)
    billing.save(expired)
    grace=SimpleNamespace(originalTransactionId=value.originalTransactionId,signedDate=value.signedDate+2000,
        autoRenewStatus=1,gracePeriodExpiresDate=int(now()+300)*1000,isInBillingRetryPeriod=True)
    billing.save_renewal(grace)
    assert billing.profile(install)["pro"] is True and billing.profile(install)["billingRetry"] is True
    revoked=tx(user,signedDate=value.signedDate+3000,revocationDate=int(now()*1000))
    billing.save(revoked)
    assert billing.profile(install)["pro"] is False
