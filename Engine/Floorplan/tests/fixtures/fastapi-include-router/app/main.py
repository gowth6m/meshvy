from fastapi import Depends, FastAPI

from app.deps import get_db_session, require_admin
from app.staff import audit
from app.routers import orders, staff
from app.routers import items as item_routes

app = FastAPI()
audit.record("start")
# The check is added once, where each router is included, not on its routes.
app.include_router(staff.router, dependencies=[Depends(require_admin)])
# Imported under another name, included over several lines beside a database session.
app.include_router(
    item_routes.router,
    prefix="/items",
    dependencies=[Depends(get_db_session), Depends(require_admin)],
)
# A database session is not a sign-in check: these routes are open.
app.include_router(orders.router, dependencies=[Depends(get_db_session)])
