import asyncio
import json
import logging
import time
import httpx
import websockets
from .models import Instrument, Quote, finite, now

log = logging.getLogger("nosce.feed")


def hyperliquid_quote(instrument, ctx, timestamp):
    price = finite(ctx["markPx"])
    previous = finite(ctx["prevDayPx"]) if ctx.get("prevDayPx") is not None else None
    change = (price / previous - 1) * 100 if previous and previous > 0 else None
    return Quote(id=instrument.id, symbol=instrument.symbol, price=price, change=change,
                 currency="USD", updated_at=timestamp, received_at=timestamp,
                 source="Hyperliquid", basis="mark", delay_seconds=0, market_state="open")


def stock_quote(instrument, payload, timestamp):
    if payload.get("status") == "error" or payload.get("symbol") != instrument.provider_symbol:
        raise ValueError("Unexpected upstream stock symbol or API error")
    if payload.get("currency") != instrument.currency:
        raise ValueError("Unexpected stock currency")
    if payload.get("exchange") != instrument.exchange:
        raise ValueError("Unexpected stock exchange")
    price = finite(payload["close"])
    quote_time = finite(payload["timestamp"])
    if quote_time <= 0 or quote_time > timestamp + 5:
        raise ValueError("Invalid upstream quote timestamp")
    previous = finite(payload["previous_close"]) if payload.get("previous_close") is not None else None
    state = "closed" if payload.get("is_market_open") is False else "open" if payload.get("is_market_open") is True else "unknown"
    return Quote(id=instrument.id, symbol=instrument.symbol, price=price,
                 change=(price/previous-1)*100 if previous and previous > 0 else None,
                 currency=instrument.currency, updated_at=quote_time, received_at=timestamp,
                 source="Twelve Data · " + instrument.exchange, basis="last",
                 delay_seconds=instrument.delay_seconds, market_state=state)


class MarketHub:
    def __init__(self, settings, store):
        self.settings, self.store = settings, store
        self.catalog: dict[str, Instrument] = {}
        self.quotes: dict[str, Quote] = {}
        self.tasks = []
        self.client = httpx.AsyncClient(timeout=15)
        self.last_catalog_at = 0
        self.watches = {}
        self.stock_reference = {}
        self.td_lock = asyncio.Lock()
        self.td_next_at = 0
        self.hl_stream_events = 0
        self.binance_stream_events = 0

    def accept_stock(self, key, value):
        previous = self.quotes.get(key)
        if previous is None or value.updated_at >= previous.updated_at:
            self.quotes[key] = value

    def stock_tick(self, data):
        key = "stock:" + data.get("exchange", "") + ":" + data.get("symbol", "")
        if key not in self.selected() or key not in self.catalog:
            return
        item = self.catalog[key]
        previous = self.stock_reference.get(key)
        value = stock_quote(item, dict(data, close=data["price"], previous_close=previous,
                                       is_market_open=True), now())
        self.accept_stock(key, value)

    def selected(self):
        self.watches = {k:v for k,v in self.watches.items() if v[1] > now()}
        shared=set()
        if self.store.is_postgres:
            rows=self.store.db.execute("SELECT payload FROM runtime_cache WHERE key LIKE ? AND updated>?",("watch:%",now()-30))
            for row in rows:shared.update(json.loads(row["payload"])["symbols"])
        return self.store.selected() | shared | {key for symbols, _, _ in self.watches.values() for key in symbols}

    def watch(self, install, connection, symbols):
        if len(self.selected() | set(symbols)) > self.settings.max_symbols:
            raise OverflowError("Market subscription capacity reached")
        self.watches[install] = (set(symbols), now()+30, connection)
        if self.store.is_postgres:self.store.put_cache("watch:"+install,{"symbols":list(symbols),"connection":connection})

    def unwatch(self, install, connection):
        if install in self.watches and self.watches[install][2] == connection:
            self.watches.pop(install, None)
        if self.store.is_postgres:
            payload,_=self.store.get_cache("watch:"+install)
            if payload and payload.get("connection")==connection:
                self.store.db.execute("DELETE FROM runtime_cache WHERE key=?",("watch:"+install,))

    async def start(self):
        from .binance_feed import stream
        self.tasks = [asyncio.create_task(self.catalog_loop()), asyncio.create_task(self.hl_loop()),
                      asyncio.create_task(self.stock_loop()), asyncio.create_task(self.stock_stream()), asyncio.create_task(stream(self))]

    async def stop(self):
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        await self.client.aclose()

    async def hl_info(self, body):
        response = await self.client.post("https://api.hyperliquid.xyz/info", json=body)
        response.raise_for_status()
        return response.json()

    async def td_get(self, endpoint, params):
        # Discovery and quote recovery share the same upstream quota/cooldown.
        async with self.td_lock:
            await asyncio.sleep(max(0, self.td_next_at - time.monotonic()))
            self.td_next_at = time.monotonic() + 60 / self.settings.stock_requests_per_minute
            if not self.store.limit("twelve-data:upstream",self.settings.stock_requests_per_minute):
                raise ValueError("Stock provider request budget reached")
            response = await self.client.get("https://api.twelvedata.com/" + endpoint, params=params,
                                             headers={"Authorization": "apikey " + self.settings.td_key})
            data = None
            try:
                data = response.json()
            except ValueError:
                pass
            if response.status_code == 429 or (isinstance(data, dict) and data.get("code") == 429):
                retry = response.headers.get("retry-after", "60")
                self.td_next_at = time.monotonic() + max(60, int(retry) if retry.isdigit() else 60)
            response.raise_for_status()
            if not isinstance(data, dict) or data.get("status") == "error":
                raise ValueError("Stock provider rejected request")
            return data

    async def catalog_loop(self):
        while True:
            failures = 0
            if self.settings.binance_enabled:
                try:
                    from .binance_feed import discover
                    await discover(self)
                except Exception:
                    failures += 1
            try:
                dexs = await self.hl_info({"type": "perpDexs"})
                for dex in [""] + [d["name"] for d in dexs if d and d.get("name")]:
                    try:
                        meta = await self.hl_info({"type": "meta", "dex": dex})
                        items = {}
                        for asset in meta["universe"]:
                            if asset.get("isDelisted"):
                                continue
                            coin = asset["name"]
                            if dex and ":" not in coin:
                                coin = dex + ":" + coin
                            key = "hl:" + coin
                            items[key] = Instrument(id=key, symbol=coin.split(":")[-1], name=coin,
                                market="Contracts" if dex else "Crypto", currency="USD",
                                provider="hyperliquid", provider_symbol=coin)
                        self.catalog = {k: v for k, v in self.catalog.items()
                                        if not (v.provider == "hyperliquid" and v.provider_symbol.rpartition(":")[0] == dex)} | items
                    except Exception:
                        failures += 1
                    await asyncio.sleep(0.3)
                if self.settings.stocks_enabled:
                    for exchange, market, currency, delay in [
                        ("NASDAQ", "US", "USD", self.settings.td_us_delay),
                        ("NYSE", "US", "USD", self.settings.td_us_delay),
                        ("HKEX", "HK", "HKD", self.settings.td_hk_delay),
                    ]:
                        if delay < 0:
                            continue
                        try:
                            result = await self.td_get("stocks", {"exchange": exchange})
                            items = {}
                            for asset in result["data"]:
                                if asset.get("exchange") != exchange or asset.get("currency") != currency:
                                    continue
                                symbol = asset["symbol"]
                                key = "stock:" + exchange + ":" + symbol
                                items[key] = Instrument(id=key, symbol=symbol, name=asset["name"],
                                    market=market, currency=currency, exchange=exchange, provider="twelvedata",
                                    provider_symbol=symbol, delay_seconds=delay)
                            self.catalog = {k:v for k,v in self.catalog.items() if v.exchange != exchange} | items
                        except Exception:
                            failures += 1
                self.last_catalog_at = now()
            except Exception:
                failures += 1
            # Error logs never include provider URLs with credentials or quote payloads.
            if failures:
                log.warning("Market discovery incomplete (%d upstream failures)", failures)
            await asyncio.sleep(60 if failures else 1800)

    def hl_selected(self):
        return {x for x in self.selected() if x in self.catalog and self.catalog[x].provider == "hyperliquid"}

    async def hl_loop(self):
        backoff = 1
        while True:
            ids = self.hl_selected()
            if not ids:
                await asyncio.sleep(1)
                continue
            try:
                # A fresh REST snapshot recovers missed updates, with the same mark-price basis.
                for dex in {self.catalog[x].provider_symbol.rpartition(":")[0] for x in ids}:
                    try:
                        metadata, contexts = await self.hl_info({"type": "metaAndAssetCtxs", "dex": dex})
                        if len(metadata["universe"]) != len(contexts):
                            raise ValueError("Universe and context mismatch")
                        for asset, context in zip(metadata["universe"], contexts):
                            coin = asset["name"]
                            if dex and ":" not in coin:
                                coin = dex + ":" + coin
                            key = "hl:" + coin
                            if key in ids and not asset.get("isDelisted"):
                                self.quotes[key] = hyperliquid_quote(self.catalog[key], context, now())
                    except Exception:
                        log.warning("Initial contract snapshot unavailable")
                async with websockets.connect("wss://api.hyperliquid.xyz/ws", ping_interval=20,
                        ping_timeout=20, max_size=1048576, open_timeout=15) as socket:
                    for key in sorted(ids):
                        await socket.send(json.dumps({"method": "subscribe", "subscription": {
                            "type": "activeAssetCtx", "coin": self.catalog[key].provider_symbol}}))
                    last_ping = now()
                    last_valid = {key: now() for key in ids}
                    while self.hl_selected() == ids:
                        if now() - last_ping >= 15:
                            await socket.send('{"method":"ping"}')
                            last_ping = now()
                        if any(now() - value > 45 for value in last_valid.values()):
                            raise TimeoutError("Contract stream stale")
                        try:
                            frame = await asyncio.wait_for(socket.recv(), 1)
                        except asyncio.TimeoutError:
                            continue
                        message = json.loads(frame)
                        if message.get("channel") == "error":
                            raise ValueError("Contract stream subscription rejected")
                        if message.get("channel") != "activeAssetCtx":
                            continue
                        payload = message["data"]
                        key = "hl:" + payload["coin"]
                        if key in ids:
                            try:
                                self.quotes[key] = hyperliquid_quote(self.catalog[key], payload["ctx"], now())
                                self.hl_stream_events += 1
                                last_valid[key] = now()
                                backoff = 1
                            except (ValueError, KeyError, TypeError):
                                log.warning("Rejected malformed contract quote")
            except asyncio.CancelledError:
                raise
            except Exception:
                log.warning("Contract stream disconnected; reconnect scheduled")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30)

    async def stock_loop(self):
        polled = {}
        while True:
            if not self.settings.stocks_enabled:
                await asyncio.sleep(5)
                continue
            keys = sorted(key for key in self.selected() if key in self.catalog and self.catalog[key].provider == "twelvedata")
            for key in keys:
                if now() - polled.get(key, 0) < 15:
                    continue
                item = self.catalog[key]
                try:
                    data = await self.td_get("quote", {"symbol": item.provider_symbol, "exchange": item.exchange})
                    value = stock_quote(item, data, now())
                    self.stock_reference[key] = data.get("previous_close")
                    self.accept_stock(key, value)
                except Exception:
                    log.warning("Stock quote unavailable; preserving original quote timestamp")
                polled[key] = now()
                # Global request budget across stocks, independent of subscriber count.
                await asyncio.sleep(60 / self.settings.stock_requests_per_minute)
            await asyncio.sleep(1)
            # Bound memory to active data; do not retain every historical subscription.
            active = self.selected()
            polled = {k:v for k,v in polled.items() if k in active}
            self.quotes = {k:v for k,v in self.quotes.items() if k in active}
            self.stock_reference = {k:v for k,v in self.stock_reference.items() if k in active}

    async def stock_stream(self):
        backoff = 1
        while True:
            ids = {key for key in self.selected() if key in self.catalog and self.catalog[key].provider == "twelvedata"}
            if not self.settings.stocks_enabled or not self.settings.td_websocket or not ids:
                await asyncio.sleep(1)
                continue
            try:
                # Header authentication keeps the provider secret out of URLs and access logs.
                async with websockets.connect("wss://ws.twelvedata.com/v1/quotes/price",
                        additional_headers={"X-TD-APIKEY": self.settings.td_key},
                        open_timeout=15, ping_interval=20, ping_timeout=20, max_size=1048576) as socket:
                    symbols = [{"symbol": self.catalog[key].provider_symbol, "exchange": self.catalog[key].exchange} for key in sorted(ids)]
                    await socket.send(json.dumps({"action": "subscribe", "params": {"symbols": symbols}}))
                    heartbeat = now()
                    while ids == {key for key in self.selected() if key in self.catalog and self.catalog[key].provider == "twelvedata"}:
                        if now()-heartbeat >= 10:
                            await socket.send('{"action":"heartbeat"}')
                            heartbeat = now()
                        try:
                            frame = await asyncio.wait_for(socket.recv(), 1)
                        except asyncio.TimeoutError:
                            continue
                        data = json.loads(frame)
                        if data.get("event") == "subscribe-status" and (data.get("status") != "ok" or data.get("fails")):
                            raise ValueError("Stock stream subscription rejected")
                        if data.get("event") == "price":
                            try:
                                self.stock_tick(data)
                                backoff = 1
                            except (ValueError, KeyError, TypeError):
                                log.warning("Rejected malformed stock tick")
            except asyncio.CancelledError:
                raise
            except Exception:
                log.warning("Stock stream disconnected; REST recovery remains active")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60)
