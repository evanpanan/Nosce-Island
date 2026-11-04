"""Public marketing pages and an explicit, credential-free release projection."""
from pathlib import Path
from urllib.parse import urlsplit
from fastapi import HTTPException
from fastapi.responses import FileResponse

PUBLIC = Path(__file__).with_name('public')
ASSETS = {'site.css': 'text/css', 'site.js': 'text/javascript', 'mark.svg': 'image/svg+xml'}
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
       "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")


def public_url(value):
    """Ignore invalid environment defaults as well as malformed stored links."""
    if not isinstance(value, str) or not value or len(value) > 1000:
        return None
    try:
        url = urlsplit(value)
        if url.scheme != 'https' or not url.hostname or url.username or url.password:
            return None
        if any(ord(char) <= 32 or char == '\\' for char in value):
            return None
        return value
    except ValueError:
        return None


def mount_public_site(app, settings):
    @app.get('/', include_in_schema=False)
    async def website():
        return FileResponse(PUBLIC / 'index.html', media_type='text/html', headers={
            'Content-Security-Policy': CSP, 'Referrer-Policy': 'strict-origin-when-cross-origin',
            'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        })

    @app.get('/site-assets/{name}', include_in_schema=False)
    async def asset(name: str):
        if name not in ASSETS:
            raise HTTPException(404, 'Asset not found')
        return FileResponse(PUBLIC / name, media_type=ASSETS[name], headers={
            'Cache-Control': 'public, max-age=3600', 'Content-Security-Policy': CSP,
        })

    @app.get('/api/public/downloads', include_in_schema=False)
    async def downloads():
        # Never serialize Settings or operator configuration to a public visitor.
        return {
            'ios': public_url(settings.ios_download_url),
            'android': public_url(settings.android_download_url),
            'privacy': public_url(settings.privacy_url),
            'terms': public_url(settings.terms_url),
        }
