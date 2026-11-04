"""Encrypted, revisioned operator configuration. Never writable by app installations."""
import base64
import json
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import replace
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography import x509
from .models import now

FIELDS={
 'alpaca_key':('Alpaca Key ID','secret'),
 'alpaca_secret':('Alpaca Secret Key','secret'),
 'alpaca_personal_user':('个人测试用户','text'),
 'apns_team_id':('Apple Team ID','text'),
 'apns_key_id':('APNs Key ID','text'),
 'apns_key_pem':('APNs .p8 私钥','secret'),
 'apns_environment':('APNs 环境','environment'),
 'app_store_issuer':('App Store Issuer ID','text'),
 'app_store_key_id':('App Store Key ID','text'),
 'app_store_key_pem':('App Store .p8 私钥','secret'),
 'app_store_roots_base64':('Apple 根证书 DER Base64','secret'),
 'app_store_environment':('内购环境','store_environment'),
 'app_store_app_id':('Apple 数字 App ID','number'),
 'app_store_products':('订阅商品 ID（逗号分隔）','text'),
 'sales_enabled':('开放购买','bool'),
 'privacy_url':('隐私政策 HTTPS 地址','url'),
 'terms_url':('用户协议 HTTPS 地址','url'),
}
KEY='operator:settings:v1'

class ConfigConflict(ValueError):pass

class RuntimeSettings:
    def __init__(self,base,store):
        self.base,self.store=base,store
        self._context=ContextVar('operator_settings_'+str(id(self)),default=None)
        self._latest=base
        self._latest_revision=0

    @property
    def current(self):return self._context.get() or self._latest

    def __getattr__(self,key):return getattr(self.current,key)

    def read(self):
        payload,revision=self.store.get_cache(KEY)
        overrides=json.loads(self.store.unseal(base64.b64decode(payload['sealed']),KEY)) if payload else {}
        return overrides,revision

    @contextmanager
    def bind(self):
        overrides,revision=self.read()
        effective=replace(self.base,**overrides)
        if revision>=self._latest_revision:
            self._latest=effective;self._latest_revision=revision
        token=self._context.set(effective)
        try:yield
        finally:self._context.reset(token)

    def describe(self):
        values,revision=self.read();cfg=replace(self.base,**values)
        return {'revision':revision,'fields':{key:{'label':label,'kind':kind,
            'configured':bool(getattr(cfg,key)), 'value':None if kind=='secret' else getattr(cfg,key),
            'source':'后台保存' if key in values else '环境变量 / 默认值'} for key,(label,kind) in FIELDS.items()},
            'alpacaEnabled':cfg.alpaca_enabled}

    def save(self,updates,revision,clear):
        if (set(updates)|set(clear))-set(FIELDS):raise ValueError('包含不支持的配置项')
        values,current=self.read()
        if revision!=current:raise ConfigConflict('配置已被更新，请关闭后重新打开再保存')
        for key in clear:values.pop(key,None)
        for key,value in updates.items():
            kind=FIELDS[key][1]
            if kind=='bool':
                if not isinstance(value,bool):raise ValueError('购买开关必须是布尔值')
            elif kind=='number':
                if isinstance(value,bool) or not isinstance(value,int) or value<0:raise ValueError('App ID 必须为非负整数')
            else:
                if not isinstance(value,str):raise ValueError('配置格式不正确')
                value=value.strip()
                if kind=='secret' and not value:continue # Blank retains stored credentials.
                if len(value)>(24000 if key=='app_store_roots_base64' else 8000 if key.endswith('_pem') else 1000):raise ValueError('配置内容过长')
                if key.endswith('_pem') and value:
                    value=value.replace('\\n','\n')
                    try:
                        signing=serialization.load_pem_private_key(value.encode(),None)
                        if not isinstance(signing,ec.EllipticCurvePrivateKey) or not isinstance(signing.curve,ec.SECP256R1):raise ValueError()
                    except Exception:raise ValueError('私钥需要是 Apple 下载的 P-256 .p8 文件内容') from None
                if key=='app_store_roots_base64' and value:
                    try:
                        for item in value.split(','):x509.load_der_x509_certificate(base64.b64decode(item.strip(),validate=True))
                    except Exception:raise ValueError('根证书需要为有效 DER 证书的 Base64，多个以逗号分隔') from None
                if kind=='url' and value:
                    from urllib.parse import urlsplit
                    url=urlsplit(value)
                    if url.scheme!='https' or not url.hostname or url.username or url.password:raise ValueError('公开协议地址必须为 HTTPS URL')
                if kind=='environment' and value not in {'development','production'}:raise ValueError('APNs 环境无效')
                if kind=='store_environment' and value not in {'Sandbox','Production'}:raise ValueError('内购环境无效')
            if key=='alpaca_personal_user' and value:
                if not self.store.db.execute('SELECT id FROM users WHERE id=? AND deleted=0',(value,)).fetchone():raise ValueError('测试用户不存在，请从已有用户中选择')
            values[key]=value
        candidate=replace(self.base,**values);candidate.validate()
        # Validate verifier construction before committing, but never pretend this contacts Apple.
        from .apple_services import AppStoreVerifier
        try:AppStoreVerifier(candidate)
        except Exception:raise ValueError('Apple 校验配置无效，请检查证书、私钥和 App ID') from None
        sealed=base64.b64encode(self.store.seal(json.dumps(values),KEY)).decode()
        stamp=max(now(),current+0.000001)
        row=self.store.db.execute('''INSERT INTO runtime_cache(key,payload,updated) VALUES(?,?,?)
          ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,updated=excluded.updated
          WHERE runtime_cache.updated=? RETURNING key''',(KEY,json.dumps({'sealed':sealed}),stamp,current)).fetchone()
        if not row:raise ConfigConflict('配置已被更新，请重新打开后再保存')
        self.store.db.execute("INSERT INTO audit(action,created) VALUES('operator.settings.updated',?)",(now(),))
        return {'ok':True,'revision':stamp}
