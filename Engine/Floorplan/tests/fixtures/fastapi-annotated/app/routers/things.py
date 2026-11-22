"""Imported alias: guarded through AdminUser from app.deps."""
from fastapi import APIRouter

from app.deps import AdminUser, SessionDep

router = APIRouter()


@router.post("/admin/things")
async def create_thing(name: str, user: AdminUser, db: SessionDep):
    return {"name": name}


@router.delete("/admin/things/{thing_id}")
async def delete_thing(thing_id: int, user: AdminUser):
    return {"deleted": thing_id}
