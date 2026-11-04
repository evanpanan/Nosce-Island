"""Fixed, public plan contract. Access always comes from verified Apple transactions."""
from fastapi import HTTPException
from .models import now

PLAN_VERSION = '2026-11-v1'

def plan_catalog():
    return {'version':PLAN_VERSION,'referenceCurrency':'USD','referenceOnly':True,
        'monthly':4.99,'yearly':39.99,'lifetime':False,
        'free':{'name':'Free','watchlistLimit':3,'islandLimit':1,'widgetFamilies':['small']},
        'pro':{'name':'Pro','watchlistLimit':8,'islandLimit':8,'widgetFamilies':['small','medium','large']},
        'sameRefreshPolicy':True,'ads':False,'paidCountdown':False,
        'excluded':['priceAlerts','portfolioPnL','watchlistSync','publicUSStocks'],
        'productIDSuggestions':['com.cooper.nosceisland.pro.monthly','com.cooper.nosceisland.pro.yearly']}

# Includes verified billing grace, excludes refunds/upgrades, and ignores obsolete renewals.
ENTITLEMENT_SQL = '''SELECT max(CASE WHEN renewals.grace>orders.expires THEN renewals.grace ELSE orders.expires END)
 FROM orders LEFT JOIN renewals ON orders.original_id=renewals.original_id
 WHERE orders.user_id=users.id AND revoked IS NULL AND upgraded=0 AND orders.transaction_id=(
 SELECT x.transaction_id FROM orders x WHERE x.original_id=orders.original_id
 ORDER BY x.purchased DESC,x.signed_at DESC LIMIT 1)'''

def access_for_expiry(expiry, timestamp=None):
    active=bool(expiry and expiry>(now() if timestamp is None else timestamp))
    key='pro' if active else 'free'
    return {'plan':key,**plan_catalog()[key],'expiresAt':expiry if active else None,'version':PLAN_VERSION}

def installation_expiries(store, installs):
    ids=list(set(installs))
    if not ids:return {}
    rows=store.db.execute('SELECT installs.id,users.deleted,('+ENTITLEMENT_SQL+') AS expiry '
        'FROM installs JOIN users ON users.id=installs.user_id WHERE installs.id IN ('+','.join('?' for _ in ids)+')',tuple(ids))
    return {row['id']:None if row['deleted'] else row['expiry'] for row in rows}

def installation_access(store, install, timestamp=None):
    return access_for_expiry(installation_expiries(store,[install]).get(install),timestamp)

def enforce_count(store, install, symbols, capability):
    access=installation_access(store,install)
    limit=access['islandLimit' if capability in {'island','widget'} else 'watchlistLimit']
    if len(symbols)>limit:
        raise HTTPException(403,detail={'code':'pro_required','feature':capability,'limit':limit,'plan':access['plan']})
    return access
