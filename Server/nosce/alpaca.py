"""Private IEX testing. Credentials stay server-side; no public redistribution path."""
import asyncio
import logging
from datetime import datetime
from zoneinfo import ZoneInfo
from .models import Instrument, Quote, finite, now

log=logging.getLogger('nosce.alpaca')
EXCHANGES={'NASDAQ','NYSE','AMEX','ARCA','NYSEARCA','BATS'}
NY=ZoneInfo('America/New_York')


def trade_time(raw):
    value=datetime.fromisoformat(raw.replace('Z','+00:00'))
    if value.tzinfo is None:raise ValueError('Missing upstream timezone')
    stamp=value.timestamp()
    if not 0 < stamp <= now()+5:raise ValueError('Invalid upstream timestamp')
    return value


def snapshot_quote(item,payload,is_open):
    trade=payload['latestTrade']
    # Never substitute SIP, bid/ask, a sample price, or the local polling time.
    if trade.get('x')!='V':raise ValueError('Expected IEX trade')
    traded=trade_time(trade['t']);price=finite(trade['p']);change=None
    previous=payload.get('prevDailyBar')
    if previous and previous.get('c') is not None:
        previous_time=trade_time(previous['t'])
        close=finite(previous['c'])
        if previous_time.astimezone(NY).date()<traded.astimezone(NY).date() and close>0:
            change=(price/close-1)*100
    return Quote(id=item.id,symbol=item.symbol,price=price,change=change,currency='USD',
        updated_at=traded.timestamp(),received_at=now(),source='Alpaca · IEX',basis='last',delay_seconds=0,
        market_state='open' if is_open is True else 'closed' if is_open is False else 'unknown')


class AlpacaFeed:
    def __init__(self,settings,store,client):
        self.settings,self.store,self.client=settings,store,client

    async def get(self,path,params=None):
        if not self.settings.alpaca_enabled:raise ValueError('Personal feed disabled')
        if not self.store.limit('alpaca:upstream',min(180,self.settings.stock_requests_per_minute)):
            raise ValueError('Alpaca request budget reached')
        base='https://data.alpaca.markets' if path=='/v2/stocks/snapshots' else 'https://paper-api.alpaca.markets'
        response=await self.client.get(base+path,params=params,headers={
            'APCA-API-KEY-ID':self.settings.alpaca_key,'APCA-API-SECRET-KEY':self.settings.alpaca_secret},timeout=8)
        if response.status_code!=200:raise ValueError('Alpaca request rejected')
        return response.json()

    async def catalog(self):
        saved,stamp=self.store.get_cache('alpaca:catalog')
        if saved and stamp>now()-86400:return {item.id:item for item in map(Instrument.model_validate,saved)}
        try:
            assets=await self.get('/v2/assets',{'status':'active','asset_class':'us_equity'})
            items=[]
            for asset in assets:
                symbol=asset.get('symbol','');exchange=asset.get('exchange','')
                if asset.get('status')!='active' or asset.get('class')!='us_equity' or exchange not in EXCHANGES:continue
                if not symbol or len(symbol)>64 or any(x in symbol for x in ',:/'):continue
                items.append(Instrument(id='stock:'+exchange+':'+symbol,symbol=symbol,name=asset.get('name') or symbol,
                    market='US',currency='USD',exchange=exchange,provider='alpaca',provider_symbol=symbol,region='US'))
            if items:self.store.put_cache('alpaca:catalog',[item.model_dump() for item in items])
            return {item.id:item for item in items}
        except Exception:
            log.warning('Personal IEX catalog unavailable; preserving prior metadata')
            return {item.id:item for item in map(Instrument.model_validate,saved or [])}

    async def quotes(self,ids):
        catalog=await self.catalog()
        if any(key not in catalog for key in ids):raise ValueError('Unknown US equity')
        values={};missing=[]
        for key in ids:
            cached,stamp=self.store.get_cache('alpaca:quote:'+key)
            if cached:values[key]=Quote.model_validate(cached)
            if not cached or stamp<=now()-15:missing.append(key)
        if not missing:return [values[key] for key in ids if key in values]
        # One personal user, shared lease across instances; no open fan-out to provider.
        lease=self.store.db.execute("""INSERT INTO runtime_cache(key,payload,updated) VALUES(?,'{}',?)
          ON CONFLICT(key) DO UPDATE SET updated=excluded.updated
          WHERE runtime_cache.updated<? RETURNING key""",('alpaca:lease',now(),now()-10)).fetchone()
        if not lease:return [values[key] for key in ids if key in values]
        try:
            snapshots,clock=await asyncio.gather(
                self.get('/v2/stocks/snapshots',{'symbols':','.join(catalog[key].provider_symbol for key in missing),'feed':'iex'}),
                self.get('/v2/clock'))
            if not isinstance(clock.get('is_open'),bool):raise ValueError('Missing market clock')
            for key in missing:
                try:
                    item=catalog[key];quote=snapshot_quote(item,snapshots[item.provider_symbol],clock['is_open'])
                    if key in values and values[key].updated_at>quote.updated_at:continue
                    values[key]=quote;self.store.put_cache('alpaca:quote:'+key,quote.model_dump())
                except (ValueError,KeyError,TypeError):continue
        except Exception:
            log.warning('Personal IEX snapshot unavailable; preserving original timestamps')
        return [values[key] for key in ids if key in values]
