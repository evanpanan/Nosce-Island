import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    serverless: bool = False
    binance_enabled: bool = True
    admin_password_hash: str = ""
    admin_totp_secret: str = ""
    admin_username: str = "admin"
    apple_signin_team: str = ""
    apple_signin_key_id: str = ""
    apple_signin_key_file: str = ""
    app_store_roots: str = ""
    app_store_environment: str = "Production"
    app_store_app_id: int = 0
    app_store_products: str = ""
    app_store_issuer: str = ""
    app_store_key_id: str = ""
    app_store_key_file: str = ""
    sales_enabled: bool = False
    privacy_url: str = ""
    terms_url: str = ""
    database: str = "/data/nosce.sqlite3"
    token_key: str = ""
    bundle_id: str = "com.cooper.nosceisland"
    apns_environment: str = "production"
    apns_team_id: str = ""
    apns_key_id: str = ""
    apns_key_file: str = ""
    apns_key_pem: str = ""
    app_store_key_pem: str = ""
    app_store_roots_base64: str = ""
    push_interval: int = 15
    heartbeat_interval: int = 60
    stale_after: int = 90
    max_sessions: int = 10000
    max_symbols: int = 64
    registration_limit: int = 20
    td_key: str = ""
    td_display_rights: bool = False
    td_websocket: bool = False
    td_us_delay: int = -1
    td_hk_delay: int = -1
    stock_requests_per_minute: int = 60

    @classmethod
    def from_env(cls):
        password = os.getenv("ADMIN_PASSWORD", "")
        encoded = os.getenv("ADMIN_PASSWORD_HASH", "")
        if password.startswith("SET_YOUR_OWN_"):
            raise ValueError("Replace the example administrator password before deployment")
        if password and not encoded:
            import hashlib
            from .admin import password_hash
            salt=hashlib.sha256((os.getenv("TOKEN_ENCRYPTION_KEY", "")+":admin-password").encode()).hexdigest()[:32]
            encoded=password_hash(password,salt)
        return cls(
            serverless=os.getenv("VERCEL", "") == "1" or os.getenv("NOSCE_RUNTIME", "") == "api",
            binance_enabled=os.getenv("BINANCE_ENABLED", "true") == "true",
            admin_password_hash=encoded,
            admin_totp_secret=os.getenv("ADMIN_TOTP_SECRET", ""),
            admin_username=os.getenv("ADMIN_USERNAME", "admin"),
            apple_signin_team=os.getenv("APPLE_SIGNIN_TEAM_ID", ""),
            apple_signin_key_id=os.getenv("APPLE_SIGNIN_KEY_ID", ""),
            apple_signin_key_file=os.getenv("APPLE_SIGNIN_KEY_FILE", ""),
            app_store_roots=os.getenv("APP_STORE_ROOT_CERTIFICATES", ""),
            app_store_environment=os.getenv("APP_STORE_ENVIRONMENT", "Production"),
            app_store_app_id=int(os.getenv("APP_STORE_APP_ID", "0")),
            app_store_products=os.getenv("APP_STORE_PRODUCT_IDS", ""),
            app_store_issuer=os.getenv("APP_STORE_ISSUER_ID", ""),
            app_store_key_id=os.getenv("APP_STORE_KEY_ID", ""),
            app_store_key_file=os.getenv("APP_STORE_KEY_FILE", ""),
            sales_enabled=os.getenv("COMMERCE_SALES_ENABLED", "false") == "true",
            privacy_url=os.getenv("PUBLIC_PRIVACY_URL", ""),
            terms_url=os.getenv("PUBLIC_TERMS_URL", ""),
            database=os.getenv("DATABASE_URL") or os.getenv("DATABASE", "/data/nosce.sqlite3"),
            token_key=os.getenv("TOKEN_ENCRYPTION_KEY", ""),
            bundle_id=os.getenv("APPLE_BUNDLE_ID", "com.cooper.nosceisland"),
            apns_environment=os.getenv("APNS_ENVIRONMENT", "production"),
            apns_team_id=os.getenv("APNS_TEAM_ID", ""),
            apns_key_id=os.getenv("APNS_KEY_ID", ""),
            apns_key_file=os.getenv("APNS_KEY_FILE", ""),
            apns_key_pem=os.getenv("APNS_PRIVATE_KEY", "").replace("\\n","\n"),
            app_store_key_pem=os.getenv("APP_STORE_PRIVATE_KEY", "").replace("\\n","\n"),
            app_store_roots_base64=os.getenv("APP_STORE_ROOT_CERTIFICATES_BASE64", ""),
            push_interval=int(os.getenv("PUSH_INTERVAL_SECONDS", "15")),
            max_sessions=int(os.getenv("MAX_SESSIONS", "10000")),
            max_symbols=int(os.getenv("MAX_ACTIVE_SYMBOLS", "64")),
            td_key=os.getenv("TWELVE_DATA_API_KEY", ""),
            td_display_rights=os.getenv("TWELVE_DATA_EXTERNAL_DISPLAY_LICENSED") == "true",
            td_websocket=os.getenv("TWELVE_DATA_WEBSOCKET_ENABLED") == "true",
            td_us_delay=int(os.getenv("TWELVE_DATA_US_DELAY_SECONDS", "-1")),
            td_hk_delay=int(os.getenv("TWELVE_DATA_HK_DELAY_SECONDS", "-1")),
            stock_requests_per_minute=int(os.getenv("STOCK_REQUESTS_PER_MINUTE", "60")),
        )

    def validate(self):
        if self.app_store_environment not in {"Production", "Sandbox"}:
            raise ValueError("APP_STORE_ENVIRONMENT must be Production or Sandbox")
        if self.admin_totp_secret and not self.admin_password_hash:
            raise ValueError("TOTP also requires an administrator password")
        if self.serverless and not self.database.startswith(("postgres://","postgresql://")):
            raise ValueError("Vercel requires persistent PostgreSQL DATABASE_URL; local SQLite is not supported")
        if len(bytes.fromhex(self.token_key)) != 32:
            raise ValueError("TOKEN_ENCRYPTION_KEY must be a persistent random 32-byte hex key")
        if self.apns_environment not in {"development", "production"}:
            raise ValueError("APNS_ENVIRONMENT must be development or production")
        if not 15 <= self.push_interval <= 60:
            raise ValueError("PUSH_INTERVAL_SECONDS must be between 15 and 60")
        if self.max_symbols < 1 or self.max_sessions < 1 or self.stock_requests_per_minute < 1:
            raise ValueError("Capacity limits must be positive")
        if not -1 <= self.td_us_delay <= 86400 or not -1 <= self.td_hk_delay <= 86400:
            raise ValueError("Stock delay must be -1 (disabled) or a licensed delay in seconds")

    @property
    def apns_configured(self):
        return bool(self.apns_team_id and self.apns_key_id and (self.apns_key_pem or (self.apns_key_file and Path(self.apns_key_file).is_file())))

    @property
    def stocks_enabled(self):
        return bool(self.td_key and self.td_display_rights)

    @property
    def signin_enabled(self):
        return bool(self.apple_signin_team and self.apple_signin_key_id and self.apple_signin_key_file
                    and Path(self.apple_signin_key_file).is_file())
