from dataclasses import replace
from fastapi.testclient import TestClient
from nosce.main import create_app
from nosce.database import Store
from nosce.operator_settings import RuntimeSettings
from nosce.public_site import public_url
from test_commerce import cfg


def test_public_home_assets_and_live_downloads_are_separate_from_admin(tmp_path):
    settings = replace(cfg(tmp_path), alpaca_secret='never-public-fixture')
    store = Store(':memory:', settings.token_key)
    app = create_app(settings, injected_store=store, run_workers=False)
    with TestClient(app) as client:
        home = client.get('/')
        assert home.status_code == 200 and '行情，' in home.text
        assert not home.history and 'Location' not in home.headers
        assert "script-src 'self'" in home.headers['Content-Security-Policy']
        assert "wss://api.hyperliquid.xyz" in home.headers['Content-Security-Policy']
        for name in ['site.css', 'site.js', 'market-feed.js', 'mark.svg']:
            response = client.get('/site-assets/' + name)
            assert response.status_code == 200
            assert 'public, max-age=' in response.headers['Cache-Control']
        assert client.get('/site-assets/config.py').status_code == 404
        assert client.get('/admin').status_code == 200
        assert client.get('/api/public/downloads').json() == dict(ios=None, android=None, privacy=None, terms=None)
        runtime = RuntimeSettings(settings, store)
        result = runtime.save({'ios_download_url':'https://testflight.apple.com/join/fixture',
                              'android_download_url':'https://example.com/app.apk',
                              'privacy_url':'https://example.com/privacy'},0,[])
        public = client.get('/api/public/downloads')
        assert public.json()['ios'] == 'https://testflight.apple.com/join/fixture'
        assert set(public.json()) == {'ios','android','privacy','terms'}
        assert 'never-public-fixture' not in public.text
        assert 'no-store' in public.headers['Cache-Control']
        runtime.save({'ios_download_url':''}, result['revision'], [])
        assert client.get('/api/public/downloads').json()['ios'] is None


def test_public_links_ignore_unsafe_values():
    for value in ['',None,'http://example.com/a','javascript:alert(1)',
                  'https://user:pass@example.com','https://example.com/\nfoo',
                  'https://example.com\\@evil.test','https://[bad']:
        assert public_url(value) is None
    assert public_url('https://example.com/download?a=1') == 'https://example.com/download?a=1'
