"""Read-only, revocable widget capability. Never expose installation or provider keys."""
import secrets
import hashlib
import hmac
import jwt
from fastapi import Header,HTTPException
from .models import StockQuoteRequest,now
from .plans import enforce_count,installation_access


def mount_widget_routes(app,settings,store,stocks,authenticate,personal_allowed):
    def entitlement_key():
        return hmac.new(bytes.fromhex(settings.token_key),b'nosce-widget-entitlement-v1',hashlib.sha256).digest()

    @app.post('/v1/widget-entitlement-access')
    async def entitlement_access(authorization:str|None=Header(default=None)):
        install=authenticate(authorization)
        if not store.limit('widget-plan:'+install,12,3600):raise HTTPException(429,'Widget registration rate exceeded')
        expires=int(now()+7*86400)
        token=jwt.encode({'sub':install,'aud':'nosce-widget-entitlement','exp':expires,'iat':int(now())},entitlement_key(),algorithm='HS256')
        return {'token':token,'expiresAt':expires}

    @app.get('/v1/widget/entitlement')
    async def widget_entitlement(authorization:str|None=Header(default=None)):
        if not authorization or not authorization.startswith('Bearer '):raise HTTPException(401,'Widget authentication required')
        try:
            claims=jwt.decode(authorization[7:],entitlement_key(),algorithms=['HS256'],audience='nosce-widget-entitlement',options={'require':['sub','exp','iat','aud']})
            install=claims['sub']
            if not isinstance(install,str) or len(install)!=32:raise ValueError()
        except (jwt.PyJWTError,ValueError,TypeError):raise HTTPException(401,'Widget entitlement access expired') from None
        owner=store.user(install)
        if not owner or owner['deleted']:raise HTTPException(401,'Widget access revoked')
        if not store.limit('widget-plan-read:'+install,30):raise HTTPException(429,'Widget request rate exceeded')
        access=installation_access(store,install)
        return {'proExpiresAt':access['expiresAt']}

    @app.post('/v1/widget-access')
    async def issue(value:StockQuoteRequest,authorization:str|None=Header(default=None)):
        install=authenticate(authorization)
        if not settings.alpaca_enabled:raise HTTPException(503,'Personal IEX data is not configured')
        if not personal_allowed(install):raise HTTPException(403,'Personal test user required')
        if not store.limit('widget-issue:'+install,12,3600):raise HTTPException(429,'Widget registration rate exceeded')
        catalog=await stocks.catalog()
        if any(key not in catalog for key in value.symbols):raise HTTPException(422,'Unsupported widget stock')
        enforce_count(store,install,value.symbols,'widget')
        token=install+'.'+secrets.token_urlsafe(32)
        expires=int(now()+7*86400)
        store.put_cache('widget-access:'+install,{'digest':store.digest(token),'symbols':value.symbols,'expires':expires})
        return {'token':token,'symbols':value.symbols,'expiresAt':expires}

    @app.post('/v1/widget/quotes')
    async def quotes(value:StockQuoteRequest,authorization:str|None=Header(default=None)):
        if not authorization or not authorization.startswith('Bearer '):raise HTTPException(401,'Widget authentication required')
        token=authorization[7:]
        install,separator,secret=token.partition('.')
        if not separator or len(install)!=32 or any(c not in '0123456789abcdef' for c in install) or not 32<=len(secret)<=64:
            raise HTTPException(401,'Invalid widget access')
        grant,_=store.get_cache('widget-access:'+install)
        if not grant or grant.get('expires',0)<=now() or not secrets.compare_digest(grant.get('digest',''),store.digest(token)):
            raise HTTPException(401,'Widget access expired')
        owner=store.user(install)
        if not owner or owner['deleted'] or not settings.alpaca_enabled or not personal_allowed(install):
            raise HTTPException(403,'Personal widget access revoked')
        if not set(value.symbols).issubset(set(grant['symbols'])):raise HTTPException(403,'Widget symbol outside granted scope')
        enforce_count(store,install,value.symbols,'widget')
        if not store.limit('widget-read:'+install,30):raise HTTPException(429,'Widget request rate exceeded')
        try:values=await stocks.quotes(value.symbols)
        except ValueError:raise HTTPException(422,'Stock is no longer available') from None
        # Widget requests do not update foreground presence, online-user counts or purchase identity.
        return {'quotes':[quote.wire() for quote in values]}
