"""Really open: only a database session, no sign-in check. Health must still flag it."""
from fastapi import APIRouter

from app.deps import SessionDep

router = APIRouter()


@router.post("/feedback")
async def send_feedback(message: str, db: SessionDep):
    return {"ok": True}
