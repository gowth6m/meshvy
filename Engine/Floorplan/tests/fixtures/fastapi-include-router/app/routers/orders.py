"""Really open: only a database session is added where it's included. Health must still flag it."""
from fastapi import APIRouter

router = APIRouter()


@router.post("/orders")
async def place_order():
    return {"ok": True}
