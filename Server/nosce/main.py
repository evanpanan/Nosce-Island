import asyncio
import json
import logging
import secrets
import sqlite3
from contextlib import asynccontextmanager, nullcontext
from fastapi import FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from .apns import APNs, push_due
from .config import Settings
from .database import Store
from .models import SessionInput, now, Instrument, Quote
from .providers import MarketHub

log = logging.getLogger("nosce")


def create_app(settings=None, injected_store=None, injected_hub=None, injected_sender=None, run_workers=True, injected_identity=None, injected_billing=None):
    settings = settings or Settings.from_env()
    settings.validate()
    if settings.serverless: run_workers = False
    store = injected_store or Store(settings.database, settings.token_key)
    hub = injected_hub or MarketHub(settings, store)
    sender = injected_sender or APNs(settings)

    from .apple_services import AppleIdentity, Billing
    from .admin import mount_admin
    from .commerce_routes import mount_commerce
    identity = injected_identity or AppleIdentity(settings,store)
    billing = injected_billing or Billing(settings,store)

    def load_snapshot():
        if not settings.serverless:return
        catalog,_=store.get_cache("catalog")
        quotes,_=store.get_cache("quotes")
        health,_=store.get_cache("heartbeat")
        hub.catalog={value["id"]:Instrument.model_validate(value) for value in (catalog or [])}
        hub.quotes={value["id"]:Quote.model_validate(value) for value in (quotes or [])}
        if health:
            hub.hl_stream_events=health.get("hlEvents",0)
            hub.binance_stream_events=health.get("binanceEvents",0)

    async def worker():
        while True:
            try:
                if settings.apns_configured:
                    await push_due(store, hub, sender, settings)
                store.cleanup()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.error("Push worker iteration failed; will retry")
            await asyncio.sleep(1)

    async def billing_worker():
        while True:
            try:
                await billing.reconcile()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.warning("Billing reconciliation iteration deferred")
            await asyncio.sleep(60)

    @asynccontextmanager
    async def lifespan(app):
        tasks = []
        if run_workers:
            await hub.start()
            tasks = [asyncio.create_task(worker()),asyncio.create_task(billing_worker())]
        try:
            yield
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await hub.stop()
            await sender.close()
            await identity.close()
            store.close()

    app = FastAPI(title="Nosce Island", version="0.6.2", lifespan=lifespan,
                  docs_url=None, redoc_url=None)
    app.state.store, app.state.hub, app.state.sender = store, hub, sender

    @app.middleware("http")
    async def guards(request: Request, call_next):
        if request.method in {"POST", "PUT", "PATCH"}:
            try:
                if int(request.headers.get("content-length", "0")) > (65536 if request.url.path.startswith(("/v1/app-store/", "/v1/purchases")) else 8192):
                    return JSONResponse({"detail": "Request too large"}, status_code=413)
            except ValueError:
                return JSONResponse({"detail": "Invalid content length"}, status_code=400)
            # Reverse proxy also enforces a body limit for chunked transfers.
        with store.db.session() if hasattr(store.db,"session") else nullcontext():
            if settings.serverless and request.url.path.startswith(("/admin/api/overview","/readyz","/v1/catalog","/v1/sessions")):
                load_snapshot()
            result = await call_next(request)
        result.headers["Cache-Control"] = "no-store"
        result.headers["X-Content-Type-Options"] = "nosniff"
        return result

    def authenticate(authorization):
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(401, "Installation authentication required")
        install = store.authenticate(authorization[7:])
        if not install:
            raise HTTPException(401, "Installation authentication expired")
        if not store.limit("install:" + install, 120):
            raise HTTPException(429, "Request rate exceeded", headers={"Retry-After": "60"})
        return install

    def validate_symbols(symbols):
        if not 1 <= len(symbols) <= 8 or len(set(symbols)) != len(symbols):
            raise HTTPException(422, "Choose one to eight distinct instruments")
        if any(key not in hub.catalog for key in symbols):
            raise HTTPException(422, "Instrument is unavailable or not licensed")

    @app.get("/")
    async def home():
        from fastapi.responses import RedirectResponse
        return RedirectResponse("/admin")

    @app.get("/healthz")
    async def health():
        return {"ok": True}

    @app.get("/readyz")
    async def readiness():
        worker_online = not settings.serverless or store.get_cache("heartbeat")[1] > now()-45
        ready = bool(settings.apns_configured and hub.catalog and worker_online)
        return JSONResponse({"ready": ready, "backgroundPush": settings.apns_configured,
              "marketCatalog": bool(hub.catalog), "workerOnline":worker_online, "stocksEnabled": settings.stocks_enabled,
              "environment": settings.apns_environment}, status_code=200 if ready else 503)

    @app.post("/v1/installations", status_code=201)
    async def install(request: Request):
        ip = request.client.host if request.client else "unknown"
        if not store.limit("registration:" + store.digest(ip), settings.registration_limit, 3600):
            raise HTTPException(429, "Registration rate exceeded", headers={"Retry-After": "3600"})
        count = store.db.execute("SELECT count(*) FROM installs").fetchone()[0]
        if count >= settings.max_sessions * 10:
            raise HTTPException(503, "Installation capacity reached")
        identifier, token = store.register()
        return {"id": identifier, "token": token}

    @app.post("/v1/presence")
    async def presence(authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        store.put_cache("presence:" + install, {})
        return {"ok": True}

    @app.get("/v1/catalog")
    async def catalog(authorization: str | None = Header(default=None),
                      offset: int = Query(default=0, ge=0), limit: int = Query(default=5000, ge=1, le=5000)):
        authenticate(authorization)
        items = sorted(hub.catalog.values(), key=lambda x: (x.id != "hl:BTC", x.id))
        return {"instruments": [x.public() for x in items[offset:offset+limit]],
                "nextOffset": offset+limit if offset+limit < len(items) else None,
                "stocksEnabled": settings.stocks_enabled}

    @app.post("/v1/sessions")
    async def session(value: SessionInput, authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        if not settings.apns_configured or (settings.serverless and store.get_cache("heartbeat")[1]<=now()-45):
            raise HTTPException(503, "Background delivery worker is not ready")
        if value.environment != settings.apns_environment:
            raise HTTPException(422, "APNs environment does not match this server")
        validate_symbols(value.symbols)
        other_symbols = {key for row in store.sessions() if row["install"] != install for key in json.loads(row["symbols"])}
        watched = {key for owner, (ids, _, _) in hub.watches.items() if owner != install for key in ids}
        if len(other_symbols | watched | set(value.symbols)) > settings.max_symbols:
            raise HTTPException(503, "Market capacity reached")
        try:
            store.upsert(install, value, settings.max_sessions, settings.max_symbols)
        except (PermissionError, sqlite3.IntegrityError):
            raise HTTPException(409, "Session ownership conflict or expired activity")
        except OverflowError:
            raise HTTPException(503, "Subscription capacity reached")
        return {"registered": True, "activityId": value.activity_id}

    @app.delete("/v1/sessions/{activity_id}", status_code=204)
    async def delete(activity_id: str, authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        store.delete(install, activity_id)

    @app.delete("/v1/installation", status_code=204)
    async def forget(authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        store.db.execute("DELETE FROM sessions WHERE install=?", (install,))
        store.db.execute("DELETE FROM ended WHERE install=?", (install,))
        store.db.execute("DELETE FROM limits WHERE key=?", ("install:" + install,))
        store.db.execute("DELETE FROM installs WHERE id=?", (install,))
        hub.watches.pop(install, None)

    @app.websocket("/v1/stream")
    async def stream(socket: WebSocket, symbols: str = ""):
        try:
            load_snapshot()
            install = authenticate(socket.headers.get("authorization"))
            ids = symbols.split(",")
            validate_symbols(ids)
        except HTTPException:
            await socket.close(code=1008)
            return
        connection = secrets.token_hex(8)
        try:
            hub.watch(install, connection, ids)
        except OverflowError:
            await socket.close(code=1013)
            return
        await socket.accept()
        try:
            while True:
                load_snapshot()
                if hub.watches.get(install, (None,None,None))[2] != connection:
                    await socket.close(code=1008)
                    break
                hub.watch(install, connection, ids)
                await socket.send_json({"quotes": [hub.quotes[key].wire() for key in ids if key in hub.quotes],
                                        "serverTime": int(now())})
                try:
                    await asyncio.wait_for(socket.receive_text(), 1)
                    await asyncio.sleep(1)
                except asyncio.TimeoutError:
                    pass
        except (WebSocketDisconnect, RuntimeError, OverflowError):
            pass
        finally:
            hub.unwatch(install, connection)

    mount_admin(app,settings,store,hub,billing)
    mount_commerce(app,settings,store,hub,identity,billing,authenticate)
    return app


def factory():
    return create_app()
