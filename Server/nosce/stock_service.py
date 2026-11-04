"""Licensed stock catalog and HTTP snapshots, including serverless deployments without a market worker."""
import asyncio
import logging
from .models import Instrument, Quote, now
from .providers import stock_quote

log=logging.getLogger('nosce.stocks')

class StockService:
    def __init__(self,settings,store,hub):
        self.settings,self.store,self.hub=settings,store,hub

    def exchanges(self):
        if not self.settings.stocks_enabled:return []
        result=[]
        if self.settings.td_us_delay>=0:
            result += [('NASDAQ','US','USD',self.settings.td_us_delay),('NYSE','US','USD',self.settings.td_us_delay)]
        if self.settings.td_hk_delay>=0:result += [('HKEX','HK','HKD',self.settings.td_hk_delay)]
        return result

    def allowed(self,item):
        return any(item.exchange==exchange and item.market==market and item.currency==currency and item.delay_seconds==delay
                   for exchange,market,currency,delay in self.exchanges()) and item.provider=='twelvedata'

    async def catalog(self):
        async def exchange_items(exchange,market,currency,delay):
            key='stocks:catalog:'+exchange
            saved,stamp=self.store.get_cache(key)
            if saved and stamp>now()-86400:
                return [Instrument.model_validate(dict(item,delay_seconds=delay)) for item in saved]
            try:
                result=await asyncio.wait_for(self.hub.td_get('stocks',{'exchange':exchange}),timeout=8)
                values=[]
                for item in result.get('data',[]):
                    symbol=item.get('symbol','')
                    if not symbol or len(symbol)>64 or item.get('exchange')!=exchange or item.get('currency')!=currency:continue
                    values.append(Instrument(id='stock:'+exchange+':'+symbol,symbol=symbol,name=item.get('name') or symbol,
                        market=market,currency=currency,exchange=exchange,provider='twelvedata',provider_symbol=symbol,
                        delay_seconds=delay,region=market))
                if values:self.store.put_cache(key,[value.model_dump() for value in values])
                return values
            except Exception:
                log.warning('Stock catalog unavailable for %s; preserving previous metadata',exchange)
                return [Instrument.model_validate(dict(item,delay_seconds=delay)) for item in (saved or [])]
        batches=await asyncio.gather(*(exchange_items(*spec) for spec in self.exchanges()))
        return {item.id:item for batch in batches for item in batch if self.allowed(item)}

    async def quotes(self,ids):
        catalog={key:item for key,item in self.hub.catalog.items() if self.allowed(item)}
        missing=[key for key in ids if key not in catalog]
        if missing:catalog.update(await self.catalog())
        unknown=[key for key in ids if key not in catalog]
        if unknown:raise ValueError('Unsupported or unlicensed stock symbol')
        async def one(key):
            cache_key='stocks:quote:'+key
            cached,stamp=self.store.get_cache(cache_key)
            old=Quote.model_validate(cached) if cached else None
            if old and old.delay_seconds!=catalog[key].delay_seconds:old=None
            if old and stamp>now()-15:return old
            # One shared short lease coalesces cold requests across serverless instances.
            lease=self.store.db.execute("""INSERT INTO runtime_cache(key,payload,updated) VALUES(?,'{}',?)
              ON CONFLICT(key) DO UPDATE SET updated=excluded.updated
              WHERE runtime_cache.updated<? RETURNING key""",('stocks:lease:'+key,now(),now()-15)).fetchone()
            if not lease:return old
            try:
                item=catalog[key]
                payload=await asyncio.wait_for(self.hub.td_get('quote',{'symbol':item.provider_symbol,'exchange':item.exchange}),timeout=8)
                quote=stock_quote(item,payload,now())
                if old and old.updated_at>quote.updated_at:return old
                self.store.put_cache(cache_key,quote.model_dump())
                return quote
            except Exception:
                log.warning('Stock quote unavailable; original price and timestamps preserved')
                return old
        values=await asyncio.gather(*(one(key) for key in ids))
        return [value for value in values if value is not None]
