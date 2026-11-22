"""Nested alias: OwnedOffice's dependency takes AdminUser itself."""
from typing import Annotated

from fastapi import APIRouter, Depends

from app.deps import AdminUser

router = APIRouter()


def load_office(office_id: int, admin: AdminUser):
    return {"id": office_id}


OwnedOffice = Annotated[dict, Depends(load_office)]


@router.put("/offices/{office_id}")
async def rename_office(office_id: int, name: str, office: OwnedOffice):
    return {"id": office_id, "name": name}
