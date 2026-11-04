import hashlib
import json
import os
import secrets
import sqlite3
import fcntl
import uuid
from pathlib import Path
from contextlib import nullcontext
from functools import wraps
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from .models import now


SCHEMA = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS installs(id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS sessions(
          id TEXT PRIMARY KEY, install TEXT NOT NULL REFERENCES installs(id), token BLOB NOT NULL,
          token_hash TEXT UNIQUE NOT NULL, symbols TEXT NOT NULL, red_up INTEGER NOT NULL,
          created REAL NOT NULL, expires REAL NOT NULL, last_push REAL NOT NULL DEFAULT 0,
          fingerprint TEXT NOT NULL DEFAULT '', failures INTEGER NOT NULL DEFAULT 0,
          retry_at REAL NOT NULL DEFAULT 0, last_stamp INTEGER NOT NULL DEFAULT 0);
        CREATE UNIQUE INDEX IF NOT EXISTS one_session_per_install ON sessions(install);
        CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY, bucket INTEGER NOT NULL, count INTEGER NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS ended(id TEXT PRIMARY KEY, install TEXT NOT NULL, ended_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, apple_hash TEXT UNIQUE, email TEXT, refresh BLOB,
          created REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS auth_challenges(id TEXT PRIMARY KEY, install TEXT NOT NULL, nonce_hash TEXT NOT NULL, expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS orders(transaction_id TEXT PRIMARY KEY, original_id TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id),
          product TEXT NOT NULL, purchased REAL NOT NULL, expires REAL, revoked REAL, signed_at REAL NOT NULL,
          upgraded INTEGER NOT NULL, price_milli INTEGER, currency TEXT, environment TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS orders_owner ON orders(user_id);
        CREATE INDEX IF NOT EXISTS orders_original ON orders(original_id);
        CREATE TABLE IF NOT EXISTS apple_events(id TEXT PRIMARY KEY, kind TEXT NOT NULL, received REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS renewals(original_id TEXT PRIMARY KEY, auto_renew INTEGER, grace REAL,
          billing_retry INTEGER NOT NULL, signed_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS reconciliations(original_id TEXT PRIMARY KEY, checked REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS admin_sessions(token_hash TEXT PRIMARY KEY, csrf TEXT NOT NULL, expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS admin_totp(step INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, action TEXT NOT NULL, created REAL NOT NULL);
"""


def serialized(method):
    @wraps(method)
    def run(self,*args,**kwargs):
        database=getattr(self,"db",None) or self.store.db
        with database.atomic() if hasattr(database,"atomic") else nullcontext():
            return method(self,*args,**kwargs)
    return run


class Store:
    """One application process; SQLite WAL persists subscriptions and retry state across restarts."""
    def __init__(self, path: str, key: str):
        self.is_postgres = path.startswith(("postgres://","postgresql://"))
        if self.is_postgres:
            from .postgres import PostgresDB
            self.lock_file = None
            self.cipher = AESGCM(bytes.fromhex(key))
            self.db = PostgresDB(path)
            self.db.initialize(SCHEMA)
            return
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.lock_file = open(path + ".lock", "a+")
            try:
                fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self.lock_file.close()
                raise RuntimeError("Run one worker/replica per database")
        else:
            self.lock_file = None
        self.db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        if path != ":memory:":
            os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.cipher = AESGCM(bytes.fromhex(key))
        self.db.executescript(SCHEMA)
        self.db.execute("CREATE TABLE IF NOT EXISTS runtime_cache(key TEXT PRIMARY KEY,payload TEXT NOT NULL,updated REAL NOT NULL)")
        user_columns = {row["name"] for row in self.db.execute("PRAGMA table_info(users)")}
        if "app_store_hash" not in user_columns:
            self.db.execute("ALTER TABLE users ADD COLUMN app_store_hash TEXT")
        self.db.execute("CREATE UNIQUE INDEX IF NOT EXISTS app_store_identity ON users(app_store_hash)")
        columns = {row["name"] for row in self.db.execute("PRAGMA table_info(installs)")}
        if "user_id" not in columns:
            self.db.execute("ALTER TABLE installs ADD COLUMN user_id TEXT")
        if "last_seen" not in columns:
            self.db.execute("ALTER TABLE installs ADD COLUMN last_seen REAL NOT NULL DEFAULT 0")
        for row in self.db.execute("SELECT id,created FROM installs WHERE user_id IS NULL").fetchall():
            user = str(uuid.uuid4())
            self.db.execute("INSERT INTO users(id,created) VALUES(?,?)", (user, row["created"]))
            self.db.execute("UPDATE installs SET user_id=? WHERE id=?", (user,row["id"]))

    @staticmethod
    def digest(value):
        return hashlib.sha256(value.encode()).hexdigest()

    @serialized
    def limit(self, key, maximum, window=60):
        bucket = int(now() // window)
        row = self.db.execute("SELECT * FROM limits WHERE key=?", (key,)).fetchone()
        if row is None and self.db.execute("SELECT count(*) FROM limits").fetchone()[0] >= 50000:
            return False
        count = row["count"] + 1 if row and row["bucket"] == bucket else 1
        self.db.execute("INSERT OR REPLACE INTO limits VALUES(?,?,?,?)", (key, bucket, count, now()))
        return count <= maximum

    @serialized
    def register(self):
        install, token = secrets.token_hex(16), secrets.token_urlsafe(32)
        user = str(uuid.uuid4())
        self.db.execute("INSERT INTO users(id,created) VALUES(?,?)", (user,now()))
        self.db.execute("INSERT INTO installs(id,token_hash,created,user_id,last_seen) VALUES(?,?,?,?,?)", (install, self.digest(token), now(),user,now()))
        return install, token

    def authenticate(self, token):
        row = self.db.execute("SELECT id FROM installs WHERE token_hash=?", (self.digest(token),)).fetchone()
        if row:
            self.db.execute("UPDATE installs SET last_seen=? WHERE id=? AND last_seen<?", (now(),row["id"],now()-60))
        return row["id"] if row else None

    def user(self, install):
        return self.db.execute("SELECT users.* FROM users JOIN installs ON users.id=installs.user_id WHERE installs.id=?", (install,)).fetchone()

    def seal(self, value, context):
        nonce = os.urandom(12)
        return nonce+self.cipher.encrypt(nonce,value.encode(),context.encode())

    def unseal(self, value, context):
        return self.cipher.decrypt(value[:12],value[12:],context.encode()).decode()

    def sessions(self, timestamp=None):
        return [dict(row) for row in self.db.execute("SELECT * FROM sessions WHERE expires>?", (timestamp or now(),))]

    def selected(self):
        return set(symbol for row in self.sessions() for symbol in json.loads(row["symbols"]))

    @serialized
    def upsert(self, install, value, maximum, max_symbols):
        timestamp = now()
        if self.db.execute("SELECT 1 FROM ended WHERE id=?", (value.activity_id,)).fetchone():
            raise PermissionError("Activity was already ended")
        row = self.db.execute("SELECT * FROM sessions WHERE id=?", (value.activity_id,)).fetchone()
        if row and row["install"] != install:
            raise PermissionError("Activity is owned by another installation")
        active = self.sessions()
        others = [entry for entry in active if entry["install"] != install]
        if not row and len(others) >= maximum:
            raise OverflowError("Session capacity reached")
        other_symbols = {symbol for entry in others for symbol in json.loads(entry["symbols"])}
        if len(other_symbols | set(value.symbols)) > max_symbols:
            raise OverflowError("Market subscription capacity reached")
        # A new APNs token never silently takes over another activity.
        owner = self.db.execute("SELECT id FROM sessions WHERE token_hash=?", (self.digest(value.push_token),)).fetchone()
        if owner and owner["id"] != value.activity_id:
            raise PermissionError("Push token is already registered")
        existing = self.db.execute("SELECT id FROM sessions WHERE install=?", (install,)).fetchone()
        if existing and existing["id"] != value.activity_id:
            # Recover from an offline stop or system dismissal that couldn't reach the API.
            self.delete(install, existing["id"])
        created = row["created"] if row else timestamp
        if created + 8 * 3600 <= timestamp:
            raise PermissionError("Activity session has expired")
        nonce = os.urandom(12)
        encrypted = nonce + self.cipher.encrypt(nonce, value.push_token.encode(), (install + value.activity_id).encode())
        self.db.execute("""INSERT INTO sessions(id,install,token,token_hash,symbols,red_up,created,expires)
          VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET token=excluded.token,
          token_hash=excluded.token_hash,symbols=excluded.symbols,red_up=excluded.red_up,
          fingerprint='',retry_at=0,failures=0""",
          (value.activity_id, install, encrypted, self.digest(value.push_token), json.dumps(value.symbols),
           int(value.red_up), created, created + 8 * 3600))

    def token(self, row):
        blob = row["token"]
        return self.cipher.decrypt(blob[:12], blob[12:], (row["install"] + row["id"]).encode()).decode()

    @serialized
    def delete(self, install, activity):
        row = self.db.execute("SELECT install FROM sessions WHERE id=?", (activity,)).fetchone()
        if row and row["install"] != install:
            return
        self.db.execute("INSERT OR IGNORE INTO ended VALUES(?,?,?)", (activity, install, now()))
        self.db.execute("DELETE FROM sessions WHERE install=? AND id=?", (install, activity))

    @serialized
    def cleanup(self):
        self.db.execute("DELETE FROM sessions WHERE expires<=?", (now(),))
        self.db.execute("DELETE FROM ended WHERE ended_at<?", (now()-86400,))
        self.db.execute("DELETE FROM installs WHERE max(created,last_seen)<? AND id NOT IN (SELECT install FROM sessions)", (now()-90*86400,))
        self.db.execute("DELETE FROM limits WHERE updated<?", (now()-86400,))
        self.db.execute("DELETE FROM admin_sessions WHERE expires<?", (now(),))
        self.db.execute("DELETE FROM auth_challenges WHERE expires<?", (now(),))
        self.db.execute("DELETE FROM admin_totp WHERE step<?", (int(now()/30)-2,))
        self.db.execute("DELETE FROM audit WHERE created<?", (now()-90*86400,))
        self.db.execute("DELETE FROM runtime_cache WHERE key LIKE ? AND updated<?",("watch:%",now()-90))
        self.db.execute("DELETE FROM runtime_cache WHERE key LIKE ? AND updated<?",("presence:%",now()-90))
        self.db.execute("DELETE FROM users WHERE apple_hash IS NULL AND id NOT IN (SELECT user_id FROM installs) AND id NOT IN (SELECT user_id FROM orders)")

    def put_cache(self,key,payload):
        self.db.execute("INSERT INTO runtime_cache VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,updated=excluded.updated",(key,json.dumps(payload,separators=(",",":")),now()))

    def get_cache(self,key):
        row=self.db.execute("SELECT payload,updated FROM runtime_cache WHERE key=?",(key,)).fetchone()
        return (json.loads(row["payload"]),row["updated"]) if row else (None,0)

    def close(self):
        self.db.close()
        if self.lock_file:
            self.lock_file.close()
