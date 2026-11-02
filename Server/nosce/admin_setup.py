"""Run on the operator's server. Never ship generated secrets in the application bundle."""
import base64
import getpass
import secrets
from urllib.parse import quote
from .admin import password_hash

if __name__ == "__main__":
    password = getpass.getpass("Administrator password (14+ characters): ")
    if password != getpass.getpass("Confirm password: "):
        raise SystemExit("Passwords differ")
    secret = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
    print("Store these locally in your protected server .env; do not commit or paste into chat.")
    print("ADMIN_PASSWORD_HASH='"+password_hash(password)+"'")
    print("ADMIN_TOTP_SECRET="+secret)
    print("Add to an authenticator app:")
    print("otpauth://totp/"+quote("Nosce Island:admin")+"?secret="+secret+"&issuer=Nosce%20Island")
