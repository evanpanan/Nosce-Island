import asyncio
import hashlib
import json
import logging
from pathlib import Path
import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from .models import now

log = logging.getLogger("nosce.push")


class APNs:
    def __init__(self, settings):
        self.settings = settings
        self.client = httpx.AsyncClient(http2=True, timeout=15)
        self.key = None
        self.jwt = ""
        self.jwt_at = 0
        self.key_signature = None
        self.reload_key()

    def reload_key(self):
        settings=self.settings
        signature=(settings.apns_key_pem,settings.apns_key_file,settings.apns_team_id,settings.apns_key_id)
        if signature==self.key_signature:return
        self.key_signature=signature;self.key=None;self.jwt_at=0;self.jwt=""
        if settings.apns_configured:
            self.key = serialization.load_pem_private_key((settings.apns_key_pem.encode() if settings.apns_key_pem else Path(settings.apns_key_file).read_bytes()), password=None)
            if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(self.key.curve, ec.SECP256R1):
                raise ValueError("APNs requires a P-256 signing key")

    def bearer(self):
        self.reload_key()
        if not self.key:
            raise RuntimeError("APNs signing is not configured")
        if now() - self.jwt_at > 3000:
            self.jwt_at = int(now())
            self.jwt = jwt.encode({"iss": self.settings.apns_team_id, "iat": self.jwt_at}, self.key,
                                  algorithm="ES256", headers={"kid": self.settings.apns_key_id})
        return self.jwt

    async def send(self, token, state, stale_at, stamp, collapse_id):
        host = "api.push.apple.com" if self.settings.apns_environment == "production" else "api.sandbox.push.apple.com"
        # Payload dates use the same ISO-8601 custom Codable contract as the iOS model.
        payload = {"aps": {"timestamp": stamp, "event": "update", "content-state": state,
                           "stale-date": int(stale_at)}}
        encoded = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > 4096:
            raise ValueError("Activity payload exceeds APNs size limit")
        response = await self.client.post("https://" + host + "/3/device/" + token,
            content=encoded, headers={"authorization": "bearer " + self.bearer(),
            "apns-topic": self.settings.bundle_id + ".push-type.liveactivity",
            "apns-push-type": "liveactivity", "apns-priority": "5",
            "apns-expiration": str(int(stale_at)),
            "apns-collapse-id": hashlib.sha256(collapse_id.encode()).hexdigest(),
            "content-type": "application/json"})
        reason = ""
        if response.status_code != 200:
            try:
                reason = response.json().get("reason", "")
            except ValueError:
                pass
        if reason == "ExpiredProviderToken":
            self.jwt_at = 0
        # APNs URLs contain private tokens; do not log raw responses/exceptions/URLs.
        retry = response.headers.get("retry-after", "60")
        return response.status_code, reason, int(retry) if retry.isdigit() else 60

    async def close(self):
        await self.client.aclose()


async def push_due(store, hub, sender, settings, timestamp=None):
    timestamp = timestamp or now()
    async def process(row):
        if row["retry_at"] > timestamp:
            return
        ids = json.loads(row["symbols"])
        quotes = [hub.quotes.get(key) for key in ids]
        # Never refresh a stale price's timestamp or synthesize a replacement.
        if not all(quotes) or not any(q.fresh(timestamp, settings.stale_after) for q in quotes):
            return
        state = {"quotes": [q.wire() for q in quotes], "redUp": bool(row["red_up"]), "foregroundOnly": False}
        # Rotate one instrument on real push updates, preserving original quote timestamps.
        pages = max(1,len(quotes))
        state["page"] = int(timestamp // settings.push_interval) % pages
        # Include the visible page so static prices still rotate while the feed remains fresh.
        fingerprint = hashlib.sha256(json.dumps([(q.id,q.price,q.change,q.market_state,q.delay_seconds) for q in quotes] + [("page",state["page"])],
                                                  separators=(",", ":")).encode()).hexdigest()
        elapsed = timestamp - row["last_push"]
        if elapsed < settings.push_interval or (fingerprint == row["fingerprint"] and elapsed < settings.heartbeat_interval):
            return
        stamp = int(timestamp)
        if stamp <= row["last_stamp"]:
            return
        stale_at = max(min(q.received_at + settings.stale_after,
            q.updated_at + q.delay_seconds + settings.stale_after) if q.market_state != "closed"
            else q.received_at + settings.stale_after for q in quotes)
        # Expired individual quotes stay explicitly expired; one outage must not freeze healthy assets.
        try:
            status, reason, retry = await sender.send(store.token(row), state, stale_at, stamp, row["id"])
        except Exception:
            status, reason, retry = 503, "TransportFailure", 60
        if status == 200:
            store.db.execute("UPDATE sessions SET last_push=?,fingerprint=?,failures=0,retry_at=0,last_stamp=? WHERE id=? AND token_hash=?",
                             (timestamp, fingerprint, stamp, row["id"], row["token_hash"]))
        elif status == 410 or reason in {"BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"}:
            current = store.db.execute("SELECT token_hash FROM sessions WHERE id=?", (row["id"],)).fetchone()
            if current and current["token_hash"] == row["token_hash"]:
                store.delete(row["install"], row["id"])
        else:
            failures = row["failures"] + 1
            delay = min(3600, max(retry, 2 ** min(failures, 10)))
            store.db.execute("UPDATE sessions SET failures=?,retry_at=? WHERE id=? AND token_hash=?", (failures, timestamp+delay, row["id"], row["token_hash"]))
            log.warning("Activity push deferred: HTTP %d, attempt %d", status, failures)

    semaphore = asyncio.Semaphore(16)
    async def bounded(row):
        async with semaphore:
            await process(row)
    await asyncio.gather(*(bounded(row) for row in store.sessions(timestamp)))
