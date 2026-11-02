"""Vercel FastAPI entrypoint. Select this repository root when importing the project."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent/"Server"))
from nosce.vercel_entry import app
