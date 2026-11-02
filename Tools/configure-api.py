"""Run on your Mac: python3 Tools/configure-api.py https://your-project.vercel.app"""
from pathlib import Path
from urllib.parse import urlsplit
import sys
if len(sys.argv)!=2:raise SystemExit("Usage: python3 Tools/configure-api.py https://your-project.vercel.app")
url=urlsplit(sys.argv[1])
if url.scheme!="https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in {"","/"} or url.hostname.endswith(".invalid"):
    raise SystemExit("Use a valid HTTPS origin with no path, credentials, query or fragment")
path=Path(__file__).resolve().parents[1]/"Config/Service.xcconfig"
lines=path.read_text().splitlines()
lines=["NOSCE_API_BASE_URL = https:/$()/"+url.netloc if line.startswith("NOSCE_API_BASE_URL =") else line for line in lines]
path.write_text("\n".join(lines)+"\n")
print("Configured API origin. Rebuild NosceIsland in Xcode.")
