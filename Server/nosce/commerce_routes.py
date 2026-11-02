from fastapi import HTTPException, Header, Request
from pydantic import BaseModel, ConfigDict, Field
from .models import now


class AppleLogin(BaseModel):
    model_config = ConfigDict(extra="forbid")
    challenge_id: str = Field(max_length=100)
    code: str = Field(max_length=4096)


class SignedTransaction(BaseModel):
    model_config = ConfigDict(extra="forbid")
    signed_transaction: str = Field(min_length=10,max_length=24000)


class StoreIdentity(BaseModel):
    model_config = ConfigDict(extra="forbid")
    signed_app_transaction: str = Field(min_length=10,max_length=24000)


class Notification(BaseModel):
    model_config = ConfigDict(extra="forbid")
    signedPayload: str = Field(min_length=10,max_length=50000)


def mount_commerce(app, settings, store, hub, identity, billing, authenticate):
    @app.get("/v1/me")
    async def profile(authorization: str | None = Header(default=None)):
        return billing.profile(authenticate(authorization))

    @app.post("/v1/apple/challenge")
    async def challenge(authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        if not settings.signin_enabled:
            raise HTTPException(503,"Apple sign-in is not configured")
        return identity.challenge(install)

    @app.post("/v1/apple/login")
    async def login(value: AppleLogin, authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        try:
            token = await identity.login(install,value.challenge_id,value.code)
        except Exception:
            raise HTTPException(401,"Apple sign-in failed; request a new challenge")
        store.db.execute("DELETE FROM sessions WHERE install=?",(install,))
        hub.watches.pop(install,None)
        return {"token":token,"profile":billing.profile(install)}

    @app.post("/v1/apple/logout")
    async def logout(authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        store.db.execute("DELETE FROM sessions WHERE install=?",(install,))
        store.db.execute("DELETE FROM installs WHERE id=?",(install,))
        hub.watches.pop(install,None)
        identifier, token = store.register()
        return {"token":token,"profile":billing.profile(identifier)}

    @app.post("/v1/app-store/identity")
    async def store_identity(value: StoreIdentity, authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        if not billing.verifier.enabled:
            raise HTTPException(503,"Purchase verification is unavailable")
        try:
            return await billing.link_store(install,value.signed_app_transaction)
        except ValueError:
            raise HTTPException(422,"Invalid App Store identity")
        except Exception:
            raise HTTPException(503,"App Store identity could not be verified; retry later")

    @app.post("/v1/purchases")
    async def purchase(value: SignedTransaction, authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        if not billing.verifier.enabled:
            raise HTTPException(503,"Purchase verification is not configured")
        try:
            return await billing.submit(install,value.signed_transaction)
        except PermissionError:
            raise HTTPException(403,"Purchase ownership could not be verified")
        except ValueError:
            raise HTTPException(422,"Invalid product or purchase")
        except Exception:
            raise HTTPException(503,"Purchase could not be verified; retry later")

    @app.post("/v1/app-store/notifications")
    async def notification(value: Notification):
        if not billing.verifier.enabled:
            raise HTTPException(503,"App Store verification is not configured")
        try:
            await billing.notify(value.signedPayload)
        except Exception:
            # No success ACK before verification and durable processing. Apple can retry.
            raise HTTPException(503,"Notification not processed")
        return {"ok":True}

    @app.delete("/v1/account")
    async def delete_account(authorization: str | None = Header(default=None)):
        install = authenticate(authorization)
        user = store.user(install)
        try:
            await identity.revoke(user)
        except Exception:
            raise HTTPException(503,"Could not revoke Apple access; retry later")
        installations = [row[0] for row in store.db.execute("SELECT id FROM installs WHERE user_id=?",(user["id"],))]
        for identifier in installations:
            store.db.execute("DELETE FROM sessions WHERE install=?",(identifier,))
            store.db.execute("DELETE FROM ended WHERE install=?",(identifier,))
            store.db.execute("DELETE FROM auth_challenges WHERE install=?",(identifier,))
            store.db.execute("DELETE FROM installs WHERE id=?",(identifier,))
            hub.watches.pop(identifier,None)
        # Keep minimal financial records linked to a pseudonymous deleted account; strip identity.
        store.db.execute("UPDATE users SET deleted=1,apple_hash=NULL,email=NULL,refresh=NULL WHERE id=?",(user["id"],))
        return {"deleted":True,"subscriptionCancelled":False}
