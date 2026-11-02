"""Persistent market/APNs worker for a Vercel Daemon or a dedicated container."""
import asyncio
import hashlib
import json
import os
from contextlib import asynccontextmanager
import psycopg
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from .config import Settings
from .database import Store
from .providers import MarketHub
from .apns import APNs,push_due
from .apple_services import Billing
from .models import now

last_tick=0
async def run():
    global last_tick
    cfg=Settings.from_env();cfg.validate()
    if not cfg.database.startswith(("postgres://","postgresql://")):
        raise RuntimeError("Shared PostgreSQL is required for the dedicated worker")
    store=Store(cfg.database,cfg.token_key);hub=MarketHub(cfg,store);sender=APNs(cfg);billing=Billing(cfg,store)
    # Dedicated session lock avoids duplicate push writers during deployment overlap.
    leader_url=os.getenv("WORKER_DATABASE_URL") or os.getenv("DATABASE_URL_UNPOOLED") or os.getenv("POSTGRES_URL_NON_POOLING")
    if not leader_url:raise RuntimeError("Set an unpooled WORKER_DATABASE_URL for the market worker leadership lock")
    with psycopg.connect(leader_url,autocommit=True,connect_timeout=10) as leader:
        while not leader.execute("SELECT pg_try_advisory_lock(1948736202)").fetchone()[0]:
            await asyncio.sleep(3)
        await hub.start()
        last_catalog="";last_snapshot=0;last_reconcile=0
        try:
            while True:
                leader.execute("SELECT 1") # Fail closed if leadership connection is lost.
                if cfg.apns_configured:await push_due(store,hub,sender,cfg)
                stamp=now();last_tick=stamp
                if stamp-last_snapshot>=5:
                    catalog=[v.model_dump() for v in hub.catalog.values()]
                    digest=hashlib.sha256(json.dumps(catalog,sort_keys=True).encode()).hexdigest()
                    if digest!=last_catalog:store.put_cache("catalog",catalog);last_catalog=digest
                    store.put_cache("quotes",[q.model_dump() for q in hub.quotes.values()])
                    store.put_cache("heartbeat",{"hlEvents":hub.hl_stream_events,"binanceEvents":hub.binance_stream_events})
                    store.cleanup();last_snapshot=stamp
                if stamp-last_reconcile>=60:
                    await billing.reconcile();last_reconcile=stamp
                await asyncio.sleep(1)
        finally:
            await hub.stop();await sender.close();store.close()

@asynccontextmanager
async def lifespan(app):
    task=asyncio.create_task(run())
    app.state.worker=task
    yield
    task.cancel();await asyncio.gather(task,return_exceptions=True)

app=FastAPI(lifespan=lifespan,docs_url=None,redoc_url=None)
@app.get("/health")
async def health():
    ok=not app.state.worker.done() and last_tick>now()-45
    return JSONResponse({"ok":ok},status_code=200 if ok else 503)
