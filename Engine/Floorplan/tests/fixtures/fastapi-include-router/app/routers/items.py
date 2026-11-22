"""Guarded where it's included, alongside a database session, over several lines."""
from fastapi import APIRouter

router = APIRouter()


@router.delete("/{item_id}")
async def delete_item(item_id: int):
    return {"deleted": item_id}
