import math
from datetime import datetime, timezone
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator


def now():
    return datetime.now(timezone.utc).timestamp()


def iso(timestamp: float):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Instrument(BaseModel):
    id: str
    symbol: str
    name: str
    market: Literal["Crypto", "Contracts", "US", "HK"]
    currency: Literal["USD", "HKD", "USDT"]
    provider: Literal["hyperliquid", "twelvedata", "binance"]
    provider_symbol: str
    exchange: str = ""
    delay_seconds: int = 0
    region: str = "Global"
    settlement_currency: str = ""

    def public(self):
        return self.model_dump(exclude={"provider_symbol"})


class Quote(BaseModel):
    id: str
    symbol: str
    price: float = Field(gt=0, allow_inf_nan=False)
    change: float | None = Field(default=None, allow_inf_nan=False)
    currency: Literal["USD", "HKD", "USDT"]
    updated_at: float
    received_at: float
    source: str
    basis: Literal["mark", "last"]
    delay_seconds: int = Field(ge=0)
    market_state: Literal["open", "closed", "unknown"] = "unknown"

    def fresh(self, timestamp: float, limit: int = 90):
        if timestamp - self.received_at > limit or self.updated_at > timestamp + 5:
            return False
        # A recent poll of an old open-market price does not make that price fresh.
        return self.market_state == "closed" or timestamp - self.updated_at <= self.delay_seconds + limit

    def wire(self):
        return {"id": self.id, "symbol": self.symbol, "price": self.price, "change": self.change,
                "currency": self.currency, "updatedAt": iso(self.updated_at), "receivedAt": iso(self.received_at),
                "source": self.source, "basis": self.basis, "delaySeconds": self.delay_seconds,
                "marketState": self.market_state}


class SessionInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    activity_id: str = Field(pattern=r"^[A-Za-z0-9-]{1,128}$")
    push_token: str = Field(pattern=r"^[a-f0-9]{64,512}$")
    environment: Literal["development", "production"]
    symbols: list[str] = Field(min_length=1, max_length=8)
    red_up: bool = False

    @field_validator("symbols")
    @classmethod
    def symbols_unique(cls, value):
        if len(set(value)) != len(value) or any(len(x) > 128 for x in value):
            raise ValueError("Select one to eight distinct supported instruments")
        return value


def finite(value):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("Non-finite upstream number")
    return result


class StockQuoteRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    symbols: list[str] = Field(min_length=1, max_length=8)

    @field_validator("symbols")
    @classmethod
    def valid_symbols(cls, values):
        if len(set(values)) != len(values) or any(not key.startswith("stock:") or len(key)>128 for key in values):
            raise ValueError("Select one to eight unique stock symbols")
        return values
