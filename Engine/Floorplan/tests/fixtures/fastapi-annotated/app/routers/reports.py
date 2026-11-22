"""Alias named like a check over a neutrally named function: AdminAccess guards through its own name."""
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException

router = APIRouter()


def check(x_console_token: str = Header(...)):
    if not x_console_token:
        raise HTTPException(status_code=403)
    return {"console": True}


AdminAccess = Annotated[dict, Depends(check)]


@router.post("/reports")
async def create_report(title: str, access: AdminAccess):
    return {"title": title}
