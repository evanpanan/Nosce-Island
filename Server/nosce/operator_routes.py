import asyncio
from fastapi import Request,HTTPException
from pydantic import BaseModel,ConfigDict,Field
from .operator_settings import ConfigConflict
from .alpaca import AlpacaFeed
from .models import now
from .stock_service import StockService

class ConfigPatch(BaseModel):
    model_config=ConfigDict(extra='forbid')
    values:dict=Field(default_factory=dict,max_length=20)
    revision:float=Field(ge=0)
    clear:list[str]=Field(default_factory=list,max_length=20)


def mount_operator_routes(app,settings,store,hub,runtime,session):
    @app.get('/admin/api/services/config')
    def config(request:Request):
        session(request)
        return runtime.describe()

    @app.post('/admin/api/services/config')
    def save(value:ConfigPatch,request:Request):
        session(request,True)
        try:return runtime.save(value.values,value.revision,value.clear)
        except ConfigConflict as exc:raise HTTPException(409,str(exc)) from None
        except (ValueError,TypeError,KeyError):raise HTTPException(422,'保存失败：请检查配置格式、私钥及所选用户；请勿填写示例值') from None

    @app.post('/admin/api/services/alpaca/test')
    async def test(request:Request):
        session(request,True)
        if not settings.alpaca_enabled:raise HTTPException(422,'先保存 Alpaca Key ID、Secret Key，并选择个人测试用户')
        if not store.admin_limit('operator:alpaca-test',5):raise HTTPException(429,'连接测试过于频繁，请稍后重试')
        feed=AlpacaFeed(settings,store,hub.client)
        try:
            async def run():
                # An explicit connection test bypasses metadata caches and verifies current credentials.
                assets=await feed.get('/v2/assets',{'status':'active','asset_class':'us_equity'})
                if not isinstance(assets,list):raise ValueError('Unexpected asset list')
                supported=[a for a in assets if a.get('class')=='us_equity' and a.get('status')=='active' and a.get('exchange') in {x[0] for x in StockService(settings,store,hub).exchanges()}]
                if not supported:raise ValueError('No supported assets')
                symbol=next((a['symbol'] for a in supported if a['symbol']=='AAPL'),supported[0]['symbol'])
                snapshots=await feed.get('/v2/stocks/snapshots',{'symbols':symbol,'feed':'iex'})
                # Explicitly invalidate prior credential catalog/quote caches; never relabel old prices.
                store.db.execute("DELETE FROM runtime_cache WHERE key LIKE ?",('alpaca:%',))
                return {'ok':True,'assetCount':len(supported),'quoteAvailable':bool(snapshots.get(symbol,{}).get('latestTrade')),
                        'checkedAt':now(),'message':'连接成功，请在指定测试设备的 App 自选页刷新市场列表。IEX 暂无成交的品种可能没有价格。'}
            result=await asyncio.wait_for(run(),timeout=18)
            store.put_cache('operator:alpaca-test',{'fingerprint':store.digest(settings.alpaca_key+'|'+settings.alpaca_secret+'|'+settings.alpaca_personal_user),'checkedAt':result['checkedAt'],'assetCount':result['assetCount']})
            return result
        except Exception:raise HTTPException(502,'Alpaca 连接未通过：请检查 Paper 模拟账户密钥、数据权限及服务网络；未使用演示数据代替') from None
