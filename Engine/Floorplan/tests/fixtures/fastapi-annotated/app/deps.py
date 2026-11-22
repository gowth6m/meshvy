"""Shared dependencies, imported by the routers (the common FastAPI layout)."""
from typing import Annotated

from fastapi import Depends, Header, HTTPException
from sqlmodel import Session, create_engine

engine = create_engine("sqlite://")


def get_session():
    with Session(engine) as session:
        yield session


def admin_user_dependency(authorization: str = Header(...)):
    if authorization != "Bearer admin":
        raise HTTPException(status_code=401)
    return {"role": "admin"}


SessionDep = Annotated[Session, Depends(get_session)]
AdminUser = Annotated[dict, Depends(admin_user_dependency)]
