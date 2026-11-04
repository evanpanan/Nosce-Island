import base64
import hashlib
import hmac
import json
import secrets
import struct
from contextlib import nullcontext
import sqlite3
from pathlib import Path
from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field, ConfigDict
from .models import now


def password_hash(password, salt=None):
    if len(password) < 14:
        raise ValueError("Use an administrator password of at least 14 characters")
    salt = salt or secrets.token_hex(16)
    value = hashlib.scrypt(password.encode(),salt=bytes.fromhex(salt),n=16384,r=8,p=1,dklen=32).hex()
    return "scrypt$"+salt+"$"+value


def password_valid(password, encoded):
    try:
        name,salt,digest = encoded.split("$")
        if name != "scrypt":
            return False
        value = hashlib.scrypt(password.encode(),salt=bytes.fromhex(salt),n=16384,r=8,p=1,dklen=32).hex()
        return hmac.compare_digest(value,digest)
    except (ValueError,TypeError):
        return False


def totp(secret, step):
    key = base64.b32decode(secret.upper()+"="*((-len(secret))%8))
    digest = hmac.new(key,struct.pack(">Q",step),hashlib.sha1).digest()
    offset = digest[-1]&15
    return str((struct.unpack(">I",digest[offset:offset+4])[0]&0x7fffffff)%1000000).zfill(6)


class AdminLogin(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(max_length=100)
    password: str = Field(max_length=256)
    code: str = Field(default="",pattern=r"^(?:[0-9]{6})?$")


def mount_admin(app, settings, store, hub, billing):
    def session_hash(token):
        return store.digest(token+"\0"+settings.admin_password_hash+"\0"+settings.admin_totp_secret)

    def session(request, csrf=False):
        if not settings.admin_password_hash:
            raise HTTPException(503,"Administrator access is not configured")
        token = request.cookies.get("nosce_admin","")
        row = store.db.execute("SELECT * FROM admin_sessions WHERE token_hash=? AND expires>?", (session_hash(token),now())).fetchone()
        if not row:
            raise HTTPException(401,"Administrator sign-in required")
        if csrf and not secrets.compare_digest(request.headers.get("X-CSRF-Token",""),row["csrf"]):
            raise HTTPException(403,"Invalid CSRF token")
        if not store.limit("admin:"+row["token_hash"],120):
            raise HTTPException(429,"Administrator rate limit exceeded")
        return row

    @app.get("/admin/api/config")
    async def login_config():
        return {"configured":bool(settings.admin_password_hash),"requiresTotp":bool(settings.admin_totp_secret),"version":"0.6.6"}

    @app.get("/admin",response_class=HTMLResponse)
    async def page():
        nonce = secrets.token_urlsafe(24)
        html = Path(__file__).with_name("admin.html").read_text().replace("<script>",'<script nonce="'+nonce+'">')
        response = HTMLResponse(html)
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'nonce-"+nonce+"'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        response.headers["X-Frame-Options"] = "DENY"
        return response

    @app.post("/admin/api/login")
    async def login(value: AdminLogin, request: Request):
        if not settings.admin_password_hash:
            raise HTTPException(503,"请先在 Vercel 环境变量中设置管理员密码")
        ip = request.client.host if request.client else "unknown"
        if not store.limit("admin-login:"+store.digest(ip),5,300):
            raise HTTPException(429,"尝试次数过多，请在 5 分钟后重试")
        if not secrets.compare_digest(value.username,settings.admin_username) or not password_valid(value.password,settings.admin_password_hash):
            raise HTTPException(401,"账号或密码不正确")
        if settings.admin_totp_secret:
            step = int(now()/30)
            valid_step = next((n for n in [step-1,step,step+1] if hmac.compare_digest(totp(settings.admin_totp_secret,n),value.code)),None)
            if valid_step is None:
                raise HTTPException(401,"动态码无效或已使用")
            try:
                # A unique key prevents replay even across concurrent serverless instances.
                store.db.execute("INSERT INTO admin_totp VALUES(?)",(valid_step,))
            except sqlite3.IntegrityError:
                raise HTTPException(401,"动态码无效或已使用")
        token, csrf = secrets.token_urlsafe(32),secrets.token_urlsafe(32)
        store.db.execute("INSERT INTO admin_sessions VALUES(?,?,?)",(session_hash(token),csrf,now()+8*3600))
        store.db.execute("INSERT INTO audit(action,created) VALUES('admin.login',?)",(now(),))
        from fastapi.responses import JSONResponse
        response = JSONResponse({"csrf":csrf})
        response.set_cookie("nosce_admin",token,max_age=8*3600,secure=True,httponly=True,samesite="strict",path="/admin")
        return response

    @app.get("/admin/api/session")
    async def current(request: Request):
        return {"csrf":session(request)["csrf"]}

    @app.post("/admin/api/logout")
    async def logout(request: Request):
        row = session(request,True)
        store.db.execute("DELETE FROM admin_sessions WHERE token_hash=?",(row["token_hash"],))
        from fastapi.responses import JSONResponse
        response = JSONResponse({"ok":True});response.delete_cookie("nosce_admin",path="/admin")
        return response

    @app.get("/admin/api/overview")
    async def overview(request: Request):
        session(request)
        db = store.db
        online = db.execute("""SELECT count(DISTINCT installs.user_id) AS users,count(*) AS devices
          FROM runtime_cache JOIN installs ON runtime_cache.key=('presence:' || installs.id)
          JOIN users ON users.id=installs.user_id
          WHERE runtime_cache.updated>? AND users.deleted=0""",(now()-90,)).fetchone()
        return {"users":db.execute("SELECT count(*) FROM users WHERE deleted=0").fetchone()[0],
            "onlineUsers":online["users"],"onlineDevices":online["devices"],"onlineWindowSeconds":90,
            "signedIn":db.execute("SELECT count(*) FROM users WHERE apple_hash IS NOT NULL AND deleted=0").fetchone()[0],
            "paying":db.execute("""SELECT count(DISTINCT user_id) FROM orders JOIN users ON users.id=orders.user_id
              LEFT JOIN renewals ON orders.original_id=renewals.original_id WHERE revoked IS NULL AND upgraded=0
              AND (CASE WHEN renewals.grace>orders.expires THEN renewals.grace ELSE orders.expires END)>? AND users.deleted=0
              AND orders.transaction_id=(SELECT x.transaction_id FROM orders x WHERE x.original_id=orders.original_id
                ORDER BY x.purchased DESC,x.signed_at DESC LIMIT 1)""",(now(),)).fetchone()[0],
            "sessions":len(store.sessions()),"orders":db.execute("SELECT count(*) FROM orders").fetchone()[0],
            "refunded":db.execute("SELECT count(*) FROM orders WHERE revoked IS NOT NULL").fetchone()[0],
            "grossByCurrency":[dict(row) for row in db.execute("SELECT currency,sum(price_milli)/1000.0 AS amount FROM orders WHERE revoked IS NULL AND price_milli IS NOT NULL GROUP BY currency")],
            "environment":settings.app_store_environment,"salesEnabled":settings.sales_enabled,
            "binance":settings.binance_enabled,"binanceEvents":hub.binance_stream_events,
            "hyperliquidEvents":hub.hl_stream_events,"instruments":len(hub.catalog),"apnsConfigured":settings.apns_configured,
            "verifierConfigured":billing.verifier.enabled,"runtime":"vercel" if settings.serverless else "server",
            "workerOnline":bool(store.get_cache("heartbeat")[1]>now()-45),"database":"PostgreSQL" if store.is_postgres else "SQLite"}

    @app.get("/admin/api/activities")
    async def activities(request: Request, search: str = "", offset: int = 0):
        session(request)
        if offset < 0 or len(search) > 100:
            raise HTTPException(422,"Invalid search")
        rows = store.db.execute("""SELECT sessions.id,installs.user_id AS userId,sessions.symbols,
          sessions.expires,sessions.last_push AS lastPush,sessions.failures,sessions.retry_at AS retryAt
          FROM sessions JOIN installs ON installs.id=sessions.install
          WHERE sessions.expires>? AND (sessions.id LIKE ? OR installs.user_id LIKE ?)
          ORDER BY sessions.created DESC LIMIT 50 OFFSET ?""",(now(),"%"+search+"%","%"+search+"%",offset)).fetchall()
        items=[]
        for row in rows:
            value=dict(row);value["symbols"]=json.loads(value["symbols"])
            value["groupCount"]=max(1,len(value["symbols"]))
            value["lastPage"]=int(value["lastPush"]//settings.push_interval)%value["groupCount"]+1 if value["lastPush"] else None
            items.append(value)
        return {"items":items,"nextOffset":offset+50 if len(rows)==50 else None}

    @app.get("/admin/api/users")
    async def users(request: Request, search: str = "", offset: int = 0):
        session(request)
        if offset < 0 or len(search) > 100:
            raise HTTPException(422,"Invalid search")
        rows = store.db.execute("""SELECT users.id,users.email,users.created,users.deleted,
          (users.apple_hash IS NOT NULL) AS signedIn,
          (users.app_store_hash IS NOT NULL) AS storeLinked,
          (SELECT max(last_seen) FROM installs WHERE user_id=users.id) AS lastSeen,
          (SELECT count(*) FROM orders WHERE user_id=users.id) AS orderCount,
          (SELECT max(expires) FROM orders WHERE user_id=users.id AND revoked IS NULL AND upgraded=0) AS expiresAt
          FROM users WHERE users.id LIKE ? ORDER BY users.created DESC LIMIT 50 OFFSET ?""",("%"+search+"%",offset)).fetchall()
        items=[]
        for row in rows:
            value=dict(row);value["expiresAt"]=billing.entitlement(row["id"])
            renewal=billing.renewal_status(row["id"])
            value["autoRenew"]=renewal["auto_renew"] if renewal else None
            value["billingRetry"]=bool(renewal["billing_retry"]) if renewal else False
            items.append(value)
        return {"items":items,"nextOffset":offset+50 if len(rows)==50 else None}

    @app.get("/admin/api/orders")
    async def orders(request: Request, search: str = "", offset: int = 0):
        session(request)
        if offset < 0 or len(search)>100:
            raise HTTPException(422,"Invalid search")
        rows = store.db.execute("""SELECT transaction_id,original_id,user_id,product,purchased,expires,revoked,
          price_milli,currency,environment,upgraded FROM orders WHERE user_id LIKE ? OR transaction_id LIKE ?
          ORDER BY purchased DESC LIMIT 50 OFFSET ?""",("%"+search+"%","%"+search+"%",offset)).fetchall()
        return {"items":[dict(row) for row in rows],"nextOffset":offset+50 if len(rows)==50 else None}
