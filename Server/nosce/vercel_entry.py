import os
from dataclasses import replace
from pathlib import Path
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, RedirectResponse
from .config import Settings
from .main import create_app

missing=[name for name in ("DATABASE_URL","TOKEN_ENCRYPTION_KEY","ADMIN_PASSWORD")
         if not os.getenv(name) and not (name=="ADMIN_PASSWORD" and os.getenv("ADMIN_PASSWORD_HASH"))]
if not missing:
    app=create_app(replace(Settings.from_env(),serverless=True),run_workers=False)
else:
    app=FastAPI(docs_url=None,redoc_url=None)
    @app.get("/")
    async def home():return RedirectResponse("/admin")
    @app.get("/admin",response_class=HTMLResponse)
    async def setup():
        return HTMLResponse(Path(__file__).with_name("admin.html").read_text(),headers={"Cache-Control":"no-store","X-Frame-Options":"DENY"})
    @app.get("/admin/api/config")
    async def config():return {"configured":False,"requiresTotp":False,"version":"0.7.6","missing":missing}
    @app.get("/healthz",status_code=503)
    async def health():return {"ok":False,"setupRequired":missing}
    @app.api_route("/{path:path}",methods=["GET","POST","DELETE"])
    async def unavailable(path:str):
        from fastapi.responses import JSONResponse
        return JSONResponse({"detail":"请先设置 Vercel 环境变量并重新部署。"},status_code=503)
