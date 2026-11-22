"""Same-file alias: guarded through MemberUser, defined here."""
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException

router = APIRouter()


def check_member(x_member_token: str = Header(...)):
    if not x_member_token:
        raise HTTPException(status_code=401)
    return {"member": True}


MemberUser = Annotated[dict, Depends(check_member)]


@router.post("/notes")
async def add_note(text: str, member: MemberUser):
    return {"text": text}
