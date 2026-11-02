import asyncio
import json
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
import httpx
import pytest
from fastapi.testclient import TestClient
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from nosce.config import Settings
from nosce.database import Store
from nosce.models import Instrument, Quote, SessionInput, now
from nosce.providers import MarketHub, hyperliquid_quote, stock_quote
from nosce.apns import APNs, push_due
from nosce.main import create_app


@pytest.fixture
def settings(tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path / "test-only-key.p8"
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
    return Settings(database=str(tmp_path / "state.sqlite"), token_key="01"*32,
                    apns_team_id="TESTONLY00", apns_key_id="TESTONLY01", apns_key_file=str(path))


def item(key="hl:BTC"):
    return Instrument(id=key, symbol=key.split(":")[-1], name=key, market="Crypto", currency="USD",
                      provider="hyperliquid", provider_symbol=key[3:])


def stock():
    return Instrument(id="stock:HKEX:0700", symbol="0700", name="Tencent", market="HK", currency="HKD",
                      provider="twelvedata", provider_symbol="0700", exchange="HKEX", delay_seconds=900)


def session(activity="activity-1", token="a"*64, symbols=None):
    return SessionInput(activity_id=activity, push_token=token, symbols=symbols or ["hl:BTC"], environment="production")


def quote(timestamp=None):
    return hyperliquid_quote(item(), {"markPx": "100", "prevDayPx": "80"}, timestamp or now())


class Sender:
    def __init__(self, status=200, reason="", retry=60):
        self.calls = []
        self.result = (status, reason, retry)

    async def send(self, *args):
        self.calls.append(args)
        return self.result

    async def close(self):
        pass


def test_token_encryption_and_restart(settings):
    store = Store(settings.database, settings.token_key)
    install, bearer = store.register()
    value = session()
    store.upsert(install, value, 100, 64)
    assert store.authenticate(bearer) == install
    assert store.sessions()[0]["token"] != value.push_token.encode()
    store.close()
    restarted = Store(settings.database, settings.token_key)
    assert restarted.token(restarted.sessions()[0]) == value.push_token
    assert restarted.authenticate(bearer) == install
    restarted.close()


def test_session_ownership_and_rotation(settings):
    store = Store(":memory:", settings.token_key)
    first, _ = store.register(); other, _ = store.register()
    store.upsert(first, session(), 100, 64)
    with pytest.raises(PermissionError):
        store.upsert(other, session(), 100, 64)
    with pytest.raises(PermissionError):
        store.upsert(other, session("other", "a"*64), 100, 64)
    created = store.sessions()[0]["created"]
    store.upsert(first, session(token="b"*64), 100, 64)
    assert store.token(store.sessions()[0]) == "b"*64
    assert store.sessions()[0]["created"] == created
    store.delete(other, "activity-1")
    assert len(store.sessions()) == 1
    store.delete(first, "activity-1")
    with pytest.raises(PermissionError):
        store.upsert(first, session(token="c"*64), 100, 64)


def test_bounded_subscriptions_and_no_client_prices(settings):
    store = Store(":memory:", settings.token_key)
    first, _ = store.register(); second, _ = store.register()
    store.upsert(first, session(), 1, 1)
    with pytest.raises(OverflowError):
        store.upsert(second, session("two", "b"*64, ["hl:ETH"]), 100, 1)
    with pytest.raises(OverflowError):
        store.upsert(second, session("two", "b"*64), 1, 64)
    with pytest.raises(ValueError):
        SessionInput(**session().model_dump(), price=12345)


def test_source_semantics_and_freshness():
    stamp = now()
    q = quote(stamp)
    assert q.change == 25 and q.basis == "mark" and q.currency == "USD"
    assert q.fresh(stamp+89) and not q.fresh(stamp+91)
    for invalid in ["NaN", "Infinity", "-1", "0"]:
        with pytest.raises(ValueError):
            hyperliquid_quote(item(), {"markPx": invalid}, stamp)
    payload = {"symbol": "0700", "exchange": "HKEX", "currency": "HKD", "close": "400",
               "previous_close": "380", "timestamp": stamp-900, "is_market_open": True}
    hk = stock_quote(stock(), payload, stamp)
    assert hk.currency == "HKD" and hk.delay_seconds == 900 and hk.basis == "last"
    assert hk.fresh(stamp+80) and not hk.fresh(stamp+100)
    # A fresh HTTP response containing an old quote does not reset its price age.
    old = stock_quote(stock(), dict(payload, timestamp=stamp-4000), stamp)
    assert not old.fresh(stamp)
    close = stock_quote(stock(), dict(payload, timestamp=stamp-4000, is_market_open=False), stamp)
    assert close.fresh(stamp) and close.updated_at == stamp-4000
    with pytest.raises(ValueError):
        stock_quote(stock(), dict(payload, currency="USD"), stamp)
    with pytest.raises(ValueError):
        stock_quote(stock(), dict(payload, exchange="NASDAQ"), stamp)


@pytest.mark.asyncio
async def test_push_update_dedup_heartbeat_and_stale(settings):
    store = Store(":memory:", settings.token_key)
    owner, _ = store.register(); store.upsert(owner, session(), 100, 64)
    stamp = now()
    hub = SimpleNamespace(quotes={"hl:BTC": quote(stamp)})
    sender = Sender()
    await push_due(store, hub, sender, settings, stamp)
    assert len(sender.calls) == 1
    payload = sender.calls[0][1]
    assert payload["foregroundOnly"] is False
    assert payload["quotes"][0]["updatedAt"].endswith("Z")
    await push_due(store, hub, sender, settings, stamp+20)
    assert len(sender.calls) == 1
    # An actual new source event permits an unchanged-price heartbeat.
    hub.quotes["hl:BTC"] = quote(stamp+60)
    await push_due(store, hub, sender, settings, stamp+61)
    assert len(sender.calls) == 2
    await push_due(store, hub, sender, settings, stamp+200)
    assert len(sender.calls) == 2


@pytest.mark.asyncio
@pytest.mark.parametrize("status,reason", [(410,"Unregistered"),(400,"BadDeviceToken"),(400,"DeviceTokenNotForTopic")])
async def test_dead_push_token_is_removed(settings, status, reason):
    store = Store(":memory:", settings.token_key)
    owner, _ = store.register(); store.upsert(owner, session(), 100, 64)
    await push_due(store, SimpleNamespace(quotes={"hl:BTC": quote()}), Sender(status, reason), settings)
    assert not store.sessions()


@pytest.mark.asyncio
async def test_retry_after_is_respected(settings):
    store = Store(":memory:", settings.token_key)
    owner, _ = store.register(); store.upsert(owner, session(), 100, 64)
    stamp = now(); sender = Sender(429, "TooManyRequests", 120)
    hub = SimpleNamespace(quotes={"hl:BTC": quote(stamp)})
    await push_due(store, hub, sender, settings, stamp)
    assert store.sessions()[0]["retry_at"] == stamp+120
    await push_due(store, hub, sender, settings, stamp+30)
    assert len(sender.calls) == 1


@pytest.mark.asyncio
async def test_apns_wire_headers_signature_and_environment(settings):
    sender = APNs(settings)
    async def handler(request):
        assert request.url.host == "api.push.apple.com"
        assert request.headers["apns-topic"] == settings.bundle_id + ".push-type.liveactivity"
        assert request.headers["apns-push-type"] == "liveactivity"
        assert request.headers["apns-priority"] == "5"
        import jwt
        key = serialization.load_pem_private_key(Path(settings.apns_key_file).read_bytes(), None)
        claims = jwt.decode(request.headers["authorization"][7:], key.public_key(), algorithms=["ES256"])
        assert claims["iss"] == settings.apns_team_id
        data = json.loads(request.content)
        assert data["aps"]["event"] == "update"
        assert data["aps"]["timestamp"] == 123
        assert data["aps"]["stale-date"] == 200
        assert data["aps"]["content-state"]["quotes"][0]["currency"] == "USD"
        return httpx.Response(200)
    await sender.client.aclose()
    sender.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    status, _, _ = await sender.send("a"*64, {"quotes":[quote().wire()]}, 200, 123, "activity")
    assert status == 200
    await sender.close()


def api(settings):
    store = Store(":memory:", settings.token_key)
    hub = MarketHub(settings, store)
    hub.catalog = {"hl:BTC": item()}
    hub.quotes = {"hl:BTC": quote()}
    app = create_app(settings, store, hub, Sender(), run_workers=False)
    return app


def test_api_auth_environment_validation_and_delete(settings):
    with TestClient(api(settings)) as client:
        assert client.get("/v1/catalog").status_code == 401
        installed = client.post("/v1/installations").json()
        headers = {"Authorization": "Bearer " + installed["token"]}
        assert client.get("/readyz").json()["ready"] is True
        assert client.get("/v1/catalog", headers=headers).json()["instruments"][0]["id"] == "hl:BTC"
        value = session().model_dump()
        assert client.post("/v1/sessions", json=dict(value, environment="development"), headers=headers).status_code == 422
        assert client.post("/v1/sessions", json=dict(value, symbols=["stock:HKEX:0700"]), headers=headers).status_code == 422
        assert client.post("/v1/sessions", json=dict(value, price=666), headers=headers).status_code == 422
        assert client.post("/v1/sessions", json=value, headers=headers).status_code == 200
        assert client.delete("/v1/sessions/activity-1", headers=headers).status_code == 204
        assert client.post("/v1/sessions", json=value, headers=headers).status_code == 409
        assert client.delete("/v1/installation", headers=headers).status_code == 204
        assert client.get("/v1/catalog", headers=headers).status_code == 401


def test_foreground_stream_and_background_subscription_independent(settings):
    app = api(settings)
    with TestClient(app) as client:
        install = client.post("/v1/installations").json()
        headers = {"Authorization": "Bearer " + install["token"]}
        with client.websocket_connect("/v1/stream?symbols=hl:BTC", headers=headers) as socket:
            frame = socket.receive_json()
            assert frame["quotes"][0]["id"] == "hl:BTC"
            assert "hl:BTC" in app.state.hub.selected()
            client.post("/v1/sessions", json=session().model_dump(), headers=headers)
        # Disconnecting the foreground must not remove the persisted background session.
        assert "hl:BTC" in app.state.store.selected()


def test_limits_and_missing_configuration(settings):
    cfg = replace(settings, apns_key_file="", registration_limit=1)
    with TestClient(api(cfg)) as client:
        assert client.get("/readyz").status_code == 503
        response = client.post("/v1/installations")
        assert response.status_code == 201
        assert client.post("/v1/installations").status_code == 429
        headers = {"Authorization": "Bearer " + response.json()["token"]}
        assert client.post("/v1/sessions", json=session().model_dump(), headers=headers).status_code == 503


def test_stock_licenses_are_fail_closed(settings):
    assert not settings.stocks_enabled
    assert not replace(settings, td_key="server-test-key").stocks_enabled
    assert replace(settings, td_key="server-test-key", td_display_rights=True).stocks_enabled


@pytest.mark.asyncio
async def test_stock_stream_uses_exchange_identity_and_ignores_older_snapshot(settings):
    store = Store(":memory:", settings.token_key)
    hub = MarketHub(settings, store)
    hk = stock(); hub.catalog[hk.id] = hk
    install, _ = store.register(); hub.watch(install, "ws1", [hk.id])
    stamp = now()
    hub.stock_reference[hk.id] = "380"
    hub.stock_tick({"symbol":"0700", "exchange":"HKEX", "currency":"HKD", "price":"400", "timestamp":stamp})
    assert hub.quotes[hk.id].price == 400
    older = stock_quote(hk, {"symbol":"0700", "exchange":"HKEX", "currency":"HKD", "close":"390",
                            "timestamp":stamp-30, "is_market_open":True}, stamp)
    hub.accept_stock(hk.id, older)
    assert hub.quotes[hk.id].price == 400
    hub.stock_tick({"symbol":"0700", "exchange":"NASDAQ", "currency":"USD", "price":"1", "timestamp":stamp})
    assert hub.quotes[hk.id].price == 400
    await hub.stop(); store.close()


@pytest.mark.asyncio
async def test_rotating_token_during_failed_delivery_does_not_delete_replacement(settings):
    store = Store(":memory:", settings.token_key)
    owner, _ = store.register(); store.upsert(owner, session(), 100, 64)
    class RotatingSender(Sender):
        async def send(self, *args):
            store.upsert(owner, session(token="b"*64), 100, 64)
            return 410, "Unregistered", 60
    await push_due(store, SimpleNamespace(quotes={"hl:BTC":quote()}), RotatingSender(), settings)
    assert store.token(store.sessions()[0]) == "b"*64


def test_new_activity_recovers_an_offline_stop_without_reviving_old_one(settings):
    store = Store(":memory:", settings.token_key)
    owner, _ = store.register()
    store.upsert(owner, session(), 1, 1)
    store.upsert(owner, session("replacement", "b"*64, ["hl:ETH"]), 1, 1)
    assert len(store.sessions()) == 1
    assert store.selected() == {"hl:ETH"}
    with pytest.raises(PermissionError):
        store.upsert(owner, session(), 1, 1)


def test_single_worker_database_lock(settings):
    first = Store(settings.database, settings.token_key)
    with pytest.raises(RuntimeError):
        Store(settings.database, settings.token_key)
    first.close()
