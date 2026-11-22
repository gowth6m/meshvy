"""Guarded where it's included in main.py."""
from fastapi import APIRouter

router = APIRouter(prefix="/staff")


@router.post("/reset")
async def reset_everything():
    return {"ok": True}


@router.get("/report")
async def report():
    return {"rows": []}
