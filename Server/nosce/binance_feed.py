import asyncio
import json
import logging
import websockets
from .models import Instrument, Quote, finite, now

log = logging.getLogger("nosce.binance")
BASE = "https://fapi.binance.com"
NAMES = {"BTC":"Bitcoin / 比特币","ETH":"Ethereum / 以太坊","SOL":"Solana",
    "TSLA":"Tesla / 特斯拉","NVDA":"NVIDIA / 英伟达","AAPL":"Apple / 苹果",
    "AMZN":"Amazon / 亚马逊","MSTR":"Strategy","COIN":"Coinbase",
    "HK0700":"Tencent / 腾讯控股","TENCENT":"Tencent / 腾讯控股","HK1810":"Xiaomi / 小米集团",
    "MEITUAN":"Meituan / 美团","KUAISHOU":"Kuaishou / 快手","BYD":"BYD / 比亚迪",
    "POPMART":"Pop Mart / 泡泡玛特"}


def instrument(asset):
    if asset.get("status") != "TRADING" or asset.get("contractType") != "PERPETUAL" or asset.get("quoteAsset") != "USDT":
        return None
    category = asset.get("underlyingType")
    if category not in {"COIN", "EQUITY", "HK_EQUITY"}:
        return None
    symbol = asset["symbol"]
    # HK-numbered quanto contracts preserve HKD numerical price units while settling in USDT.
    # Never infer the displayed price unit solely from quoteAsset=USDT.
    quanto_hk = category == "HK_EQUITY" and symbol.startswith("HK") and symbol[2:-4].isdigit()
    return Instrument(id="bn:"+symbol, symbol=asset["baseAsset"], name=NAMES.get(asset["baseAsset"],asset["baseAsset"]),
        market="Crypto" if category == "COIN" else "Contracts", provider="binance", provider_symbol=symbol,
        currency="HKD" if quanto_hk else "USDT", region="HK" if category == "HK_EQUITY" else "US" if category == "EQUITY" else "Global",
        settlement_currency=asset.get("marginAsset", "USDT"))


def mark_quote(item, payload):
    if payload.get("s", payload.get("symbol")) != item.provider_symbol:
        raise ValueError("Mismatched Binance symbol")
    timestamp = finite(payload.get("E", payload.get("time"))) / 1000
    received = now()
    if timestamp <= 0 or timestamp > received + 5:
        raise ValueError("Invalid Binance event time")
    return Quote(id=item.id, symbol=item.symbol, price=finite(payload.get("p", payload.get("markPrice"))),
        change=None, currency=item.currency, updated_at=timestamp, received_at=received,
        source="Binance Futures", basis="mark", delay_seconds=0, market_state="open")


async def discover(hub):
    response = await hub.client.get(BASE+"/fapi/v1/exchangeInfo")
    response.raise_for_status()
    items = {}
    for asset in response.json()["symbols"]:
        value = instrument(asset)
        if value:
            items[value.id] = value
    hub.catalog = {key:value for key,value in hub.catalog.items() if value.provider != "binance"} | items


async def stream(hub):
    backoff = 1
    def selected():
        return {key for key in hub.selected() if key in hub.catalog and hub.catalog[key].provider == "binance"}
    while True:
        ids = selected()
        if not hub.settings.binance_enabled or not ids:
            await asyncio.sleep(1)
            continue
        try:
            # No API key or broker login is attached to these public requests.
            for key in ids:
                try:
                    response = await hub.client.get(BASE+"/fapi/v1/premiumIndex", params={"symbol":hub.catalog[key].provider_symbol})
                    response.raise_for_status()
                    hub.quotes[key] = mark_quote(hub.catalog[key], response.json())
                except Exception:
                    log.warning("Binance initial snapshot unavailable")
            async with websockets.connect("wss://fstream.binance.com/market/stream", open_timeout=15,
                    ping_interval=20, ping_timeout=20, max_size=1048576) as socket:
                await socket.send(json.dumps({"method":"SUBSCRIBE", "params":[hub.catalog[key].provider_symbol.lower()+"@markPrice@1s" for key in sorted(ids)], "id":1}))
                last_seen = {key: now() for key in ids}
                while selected() == ids:
                    if any(now()-stamp > 30 for stamp in last_seen.values()):
                        raise TimeoutError("Binance feed stale")
                    try:
                        value = json.loads(await asyncio.wait_for(socket.recv(), 1))
                    except asyncio.TimeoutError:
                        continue
                    payload = value.get("data", value)
                    if payload.get("code") is not None:
                        raise ValueError("Binance subscription rejected")
                    if payload.get("e") != "markPriceUpdate":
                        continue
                    key = "bn:"+payload.get("s", "")
                    if key in ids:
                        try:
                            quote = mark_quote(hub.catalog[key], payload)
                            previous = hub.quotes.get(key)
                            if not previous or quote.updated_at >= previous.updated_at:
                                hub.quotes[key] = quote
                                last_seen[key] = now()
                                hub.binance_stream_events += 1
                                backoff = 1
                        except (ValueError, TypeError, KeyError):
                            log.warning("Rejected malformed Binance quote")
        except asyncio.CancelledError:
            raise
        except Exception:
            log.warning("Binance feed disconnected; reconnect scheduled")
            await asyncio.sleep(backoff)
            backoff = min(30, backoff*2)
