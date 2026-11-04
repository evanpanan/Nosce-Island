import asyncio
import base64
from contextlib import nullcontext
from .database import serialized
import hashlib
import secrets
import sqlite3
import uuid
from pathlib import Path
import httpx
import jwt
from .models import now


class AppleIdentity:
    def __init__(self, settings, store):
        self.settings, self.store = settings, store
        self.client = httpx.AsyncClient(timeout=15)
        self.keys, self.keys_at = {}, 0

    def challenge(self, install):
        self.store.db.execute("DELETE FROM auth_challenges WHERE install=?", (install,))
        key, nonce = secrets.token_urlsafe(24), secrets.token_urlsafe(32)
        self.store.db.execute("INSERT INTO auth_challenges VALUES(?,?,?,?)",
            (key,install,hashlib.sha256(nonce.encode()).hexdigest(),now()+300))
        return {"id":key,"nonce":nonce}

    def client_secret(self):
        cfg = self.settings
        key = Path(cfg.apple_signin_key_file).read_bytes()
        return jwt.encode({"iss":cfg.apple_signin_team,"iat":int(now()),"exp":int(now())+300,
             "aud":"https://appleid.apple.com","sub":cfg.bundle_id}, key, algorithm="ES256",
             headers={"kid":cfg.apple_signin_key_id})

    async def login(self, install, challenge, code):
        cfg, db = self.settings, self.store.db
        entry = db.execute("SELECT * FROM auth_challenges WHERE id=? AND install=? AND expires>?", (challenge,install,now())).fetchone()
        if not cfg.signin_enabled or not entry:
            raise ValueError("Apple sign-in is unavailable or challenge expired")
        db.execute("DELETE FROM auth_challenges WHERE id=?", (challenge,))
        response = await self.client.post("https://appleid.apple.com/auth/token", data={
            "client_id":cfg.bundle_id,"client_secret":self.client_secret(),"grant_type":"authorization_code","code":code})
        response.raise_for_status()
        result = response.json()
        token = result["id_token"]
        header = jwt.get_unverified_header(token)
        if header.get("alg") != "RS256":
            raise ValueError("Unsupported identity signature")
        if now()-self.keys_at > 3600 or header.get("kid") not in self.keys:
            response = await self.client.get("https://appleid.apple.com/auth/keys")
            response.raise_for_status()
            self.keys = {key["kid"]:jwt.PyJWK.from_dict(key).key for key in response.json()["keys"]}
            self.keys_at = now()
        claims = jwt.decode(token,self.keys[header["kid"]],algorithms=["RS256"],audience=cfg.bundle_id,
            issuer="https://appleid.apple.com",options={"require":["exp","iat","sub","aud","iss","nonce"]})
        if not secrets.compare_digest(claims["nonce"],entry["nonce_hash"]):
            raise ValueError("Identity nonce mismatch")
        subject = self.store.digest(claims["sub"])
        user = db.execute("SELECT * FROM users WHERE apple_hash=? AND deleted=0", (subject,)).fetchone()
        current = self.store.user(install)
        user_id = user["id"] if user else current["id"] if current["apple_hash"] is None else str(uuid.uuid4())
        email = claims.get("email") if claims.get("email_verified") in {True,"true"} else None
        refresh = result.get("refresh_token")
        if not refresh:
            raise ValueError("Missing revocable Apple session")
        db.execute("INSERT OR IGNORE INTO users(id,created) VALUES(?,?)", (user_id,now()))
        db.execute("UPDATE users SET apple_hash=?,email=COALESCE(?,email),refresh=? WHERE id=?",
                   (subject,email,self.store.seal(refresh,user_id),user_id))
        token = secrets.token_urlsafe(32)
        # Rotate credentials when an anonymous installation gains an account identity.
        db.execute("UPDATE installs SET user_id=?,token_hash=? WHERE id=?", (user_id,self.store.digest(token),install))
        return token

    async def revoke(self, user):
        if not user["refresh"]:
            return
        response = await self.client.post("https://appleid.apple.com/auth/revoke", data={
            "client_id":self.settings.bundle_id,"client_secret":self.client_secret(),
            "token":self.store.unseal(user["refresh"],user["id"]),"token_type_hint":"refresh_token"})
        response.raise_for_status()

    async def close(self):
        await self.client.aclose()


class AppStoreVerifier:
    def __init__(self, settings):
        self.settings = settings
        self.verifier = self.api = None
        roots = [Path(path.strip()) for path in settings.app_store_roots.split(",") if path.strip()]
        cfg = settings
        certificates=[path.read_bytes() for path in roots if path.is_file()]
        if settings.app_store_roots_base64:
            certificates += [base64.b64decode(value.strip(),validate=True) for value in settings.app_store_roots_base64.split(",") if value.strip()]
        if not certificates or len(certificates) < len(roots):
            return
        if not (cfg.app_store_issuer and cfg.app_store_key_id and (cfg.app_store_key_pem or (cfg.app_store_key_file and Path(cfg.app_store_key_file).is_file()))):
            return
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
        from appstoreserverlibrary.api_client import AppStoreServerAPIClient
        environment = Environment.PRODUCTION if cfg.app_store_environment == "Production" else Environment.SANDBOX
        if environment == Environment.PRODUCTION and not cfg.app_store_app_id:
            return
        self.verifier = SignedDataVerifier(certificates,True,environment,cfg.bundle_id,
                                           cfg.app_store_app_id or None)
        self.api = AppStoreServerAPIClient(cfg.app_store_key_pem.encode() if cfg.app_store_key_pem else Path(cfg.app_store_key_file).read_bytes(),cfg.app_store_key_id,
                                          cfg.app_store_issuer,cfg.bundle_id,environment)

    @property
    def enabled(self):
        return self.verifier is not None and self.api is not None

    async def transaction(self, signed):
        if not self.enabled:
            raise RuntimeError("App Store verification not configured")
        return await asyncio.to_thread(self.verifier.verify_and_decode_signed_transaction,signed)

    async def app_transaction(self, signed):
        if not self.enabled:
            raise RuntimeError("App Store verification not configured")
        return await asyncio.to_thread(self.verifier.verify_and_decode_app_transaction,signed)

    async def fresh_transaction(self, signed):
        tx = await self.transaction(signed)
        response = await asyncio.to_thread(self.api.get_transaction_info,tx.transactionId)
        return await self.transaction(response.signedTransactionInfo)

    async def notification(self, signed):
        if not self.enabled:
            raise RuntimeError("App Store verification not configured")
        return await asyncio.to_thread(self.verifier.verify_and_decode_notification,signed)

    async def renewal(self, signed):
        return await asyncio.to_thread(self.verifier.verify_and_decode_renewal_info,signed)


class Billing:
    def __init__(self, settings, store, verifier=None):
        self.settings, self.store = settings, store
        self._fixed_verifier = verifier
        self._verifiers = {}

    @property
    def verifier(self):
        if self._fixed_verifier is not None:return self._fixed_verifier
        cfg=getattr(self.settings,'current',self.settings)
        cached=self._verifiers.get(cfg)
        if cached is not None:return cached
        value=AppStoreVerifier(cfg)
        if len(self._verifiers)>3:self._verifiers.clear()
        self._verifiers[cfg]=value
        return value

    @property
    def products(self):
        return {value.strip() for value in self.settings.app_store_products.split(",") if value.strip()}

    async def link_store(self, install, signed):
        value = await self.verifier.app_transaction(signed)
        environment = getattr(value.receiptType,"value",value.receiptType)
        if value.bundleId != self.settings.bundle_id or environment != self.settings.app_store_environment:
            raise ValueError("Wrong app or environment")
        identifier = value.appTransactionId
        if not isinstance(identifier,str) or not identifier or len(identifier)>256:
            raise ValueError("Missing App Store identity")
        with self.store.db.atomic() if hasattr(self.store.db,"atomic") else nullcontext():
            identity = self.store.digest("app-store:" + environment + ":" + identifier)
            db = self.store.db
            target = db.execute("SELECT id FROM users WHERE app_store_hash=? AND deleted=0",(identity,)).fetchone()
            current = self.store.user(install)
            owner = target["id"] if target else current["id"] if not current["app_store_hash"] else str(uuid.uuid4())
            db.execute("INSERT OR IGNORE INTO users(id,created) VALUES(?,?)",(owner,now()))
            db.execute("UPDATE users SET app_store_hash=? WHERE id=?",(identity,owner))
            db.execute("UPDATE installs SET user_id=? WHERE id=?",(owner,install))
        return self.profile(install)

    @serialized
    def save(self, tx, required_user=None):
        owner = str(uuid.UUID(str(tx.appAccountToken)))
        if required_user and owner != required_user:
            raise PermissionError("Purchase belongs to another app account")
        if tx.productId not in self.products or tx.bundleId != self.settings.bundle_id:
            raise ValueError("Unconfigured product or bundle")
        environment = getattr(tx.environment,"value",tx.environment)
        if environment != self.settings.app_store_environment:
            raise ValueError("Wrong App Store environment")
        if getattr(tx.type,"value",tx.type) != "Auto-Renewable Subscription":
            raise ValueError("Only configured subscriptions are accepted")
        if not tx.transactionId or not tx.originalTransactionId or not tx.signedDate or not tx.expiresDate:
            raise ValueError("Incomplete transaction")
        if tx.purchaseDate/1000>now()+300 or tx.expiresDate<tx.purchaseDate:
            raise ValueError("Invalid purchase dates")
        user = self.store.db.execute("SELECT id FROM users WHERE id=?", (owner,)).fetchone()
        if not user:
            raise ValueError("Unknown app account")
        previous = self.store.db.execute("SELECT user_id FROM orders WHERE original_id=? OR transaction_id=? LIMIT 1",
                                           (tx.originalTransactionId,tx.transactionId)).fetchone()
        if previous and previous["user_id"] != owner:
            raise PermissionError("Purchase ownership conflict")
        self.store.db.execute("""INSERT INTO orders VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(transaction_id)
          DO UPDATE SET expires=excluded.expires,revoked=excluded.revoked,signed_at=excluded.signed_at,
          upgraded=excluded.upgraded WHERE excluded.signed_at > orders.signed_at""",
          (tx.transactionId,tx.originalTransactionId,owner,tx.productId,tx.purchaseDate/1000,tx.expiresDate/1000,
           tx.revocationDate/1000 if tx.revocationDate else None,tx.signedDate/1000,int(bool(tx.isUpgraded)),
           tx.price,tx.currency,environment))

    def profile(self, install):
        user = self.store.user(install)
        latest = self.entitlement(user["id"])
        pro = not user["deleted"] and bool(latest and latest > now())
        renewal=self.renewal_status(user["id"])
        return {"userId":user["id"],"signedIn":bool(user["apple_hash"]),"email":user["email"],
                "pro":pro,"expiresAt":latest,"autoRenew":renewal["auto_renew"] if renewal else None,
                "billingRetry":bool(renewal["billing_retry"]) if renewal else False,"signInEnabled":False,"storeLinked":bool(user["app_store_hash"]),
                "verificationEnabled":bool(self.verifier.enabled),
                "purchaseEnabled":bool(self.settings.sales_enabled and self.verifier.enabled and self.products
                    and self.settings.privacy_url.startswith("https://") and self.settings.terms_url.startswith("https://")),
                "privacyURL":self.settings.privacy_url or None,"termsURL":self.settings.terms_url or None,
                "productIds":sorted(self.products)}

    def renewal_status(self, user):
        return self.store.db.execute("""SELECT renewals.* FROM renewals JOIN orders ON orders.original_id=renewals.original_id
          WHERE orders.user_id=? ORDER BY renewals.signed_at DESC LIMIT 1""",(user,)).fetchone()

    def entitlement(self, user):
        return self.store.db.execute("""SELECT max(CASE WHEN renewals.grace>orders.expires THEN renewals.grace ELSE orders.expires END)
          FROM orders LEFT JOIN renewals ON orders.original_id=renewals.original_id
          WHERE orders.user_id=? AND revoked IS NULL AND upgraded=0 AND orders.transaction_id=(
            SELECT x.transaction_id FROM orders x WHERE x.original_id=orders.original_id
            ORDER BY x.purchased DESC,x.signed_at DESC LIMIT 1)""",(user,)).fetchone()[0]

    @serialized
    def save_renewal(self, value):
        if not value.originalTransactionId or not value.signedDate:
            raise ValueError("Incomplete renewal state")
        if not self.store.db.execute("SELECT 1 FROM orders WHERE original_id=?",(value.originalTransactionId,)).fetchone():
            raise ValueError("Unknown renewal")
        status=getattr(value.autoRenewStatus,"value",value.autoRenewStatus)
        self.store.db.execute("""INSERT INTO renewals VALUES(?,?,?,?,?) ON CONFLICT(original_id) DO UPDATE SET
          auto_renew=excluded.auto_renew,grace=excluded.grace,billing_retry=excluded.billing_retry,signed_at=excluded.signed_at
          WHERE excluded.signed_at>renewals.signed_at""",(value.originalTransactionId,status,
          value.gracePeriodExpiresDate/1000 if value.gracePeriodExpiresDate else None,
          int(bool(value.isInBillingRetryPeriod)),value.signedDate/1000))

    async def submit(self, install, signed):
        user = self.store.user(install)
        if not (user["app_store_hash"] or user["apple_hash"]) or user["deleted"]:
            raise PermissionError("Verify App Store identity before purchasing or restoring")
        tx = await self.verifier.fresh_transaction(signed)
        if user["app_store_hash"]:
            identifier = getattr(tx,"appTransactionId",None)
            expected = self.store.digest("app-store:" + self.settings.app_store_environment + ":" + str(identifier))
            if not identifier or not secrets.compare_digest(expected,user["app_store_hash"]):
                raise PermissionError("Purchase App Store identity mismatch")
        self.save(tx,user["id"])
        return self.profile(install)

    async def notify(self, signed):
        notification = await self.verifier.notification(signed)
        identifier = str(notification.notificationUUID)
        if self.store.db.execute("SELECT 1 FROM apple_events WHERE id=?", (identifier,)).fetchone():
            return
        if notification.data and notification.data.signedTransactionInfo:
            tx = await self.verifier.transaction(notification.data.signedTransactionInfo)
            self.save(tx)
            if getattr(notification.data,"signedRenewalInfo",None):
                renewal=await self.verifier.renewal(notification.data.signedRenewalInfo)
                if renewal.originalTransactionId != tx.originalTransactionId:
                    raise ValueError("Mismatched renewal ownership")
                self.save_renewal(renewal)
        self.store.db.execute("INSERT OR IGNORE INTO apple_events VALUES(?,?,?)", (identifier,str(notification.notificationType),now()))

    async def reconcile(self):
        """Recover missed server notifications using Apple's authenticated subscription status API."""
        if not self.verifier.enabled or not hasattr(self.verifier,"api"):
            return
        rows=self.store.db.execute("""SELECT DISTINCT orders.original_id FROM orders LEFT JOIN reconciliations
          ON orders.original_id=reconciliations.original_id WHERE COALESCE(reconciliations.checked,0)<?
          ORDER BY COALESCE(reconciliations.checked,0) LIMIT 100""",(now()-3600,)).fetchall()
        for row in rows:
            original=row[0]
            try:
                response=await asyncio.to_thread(self.verifier.api.get_all_subscription_statuses,original)
                for group in response.data or []:
                    for entry in group.lastTransactions or []:
                        if entry.originalTransactionId != original:
                            continue
                        value=await self.verifier.transaction(entry.signedTransactionInfo)
                        self.save(value)
                        if entry.signedRenewalInfo:
                            self.save_renewal(await self.verifier.renewal(entry.signedRenewalInfo))
                self.store.db.execute("INSERT OR REPLACE INTO reconciliations VALUES(?,?)",(original,now()))
            except Exception:
                import logging
                logging.getLogger("nosce.billing").warning("App Store reconciliation deferred")
                # Slow down all reconciliation after a remote failure/rate limit.
                return
            await asyncio.sleep(0.5)
