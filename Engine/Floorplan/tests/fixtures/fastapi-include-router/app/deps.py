"""Shared dependencies: one checks the caller, one only hands over a database session."""
from fastapi import Header, HTTPException


def get_db_session():
    yield object()


def require_admin(authorization: str = Header(...)):
    if authorization != "Bearer admin":
        raise HTTPException(status_code=401)
