"""Really open: only a database session from a less common helper name. Health must still flag it."""
from typing import Annotated

from fastapi import APIRouter, Depends
from sqlmodel import Session

from app.deps import engine

router = APIRouter()


def get_sql_session():
    with Session(engine) as session:
        yield session


SqlSessionDep = Annotated[Session, Depends(get_sql_session)]


@router.post("/comments")
async def add_comment(text: str, db: SqlSessionDep):
    return {"ok": True}
