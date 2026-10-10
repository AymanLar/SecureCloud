from fastapi import APIRouter, HTTPException, Request
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.schemas import HealthResponse

router = APIRouter(prefix="/api/health", tags=["health"])


@router.get("", response_model=HealthResponse)
def health(request: Request) -> HealthResponse:
    return HealthResponse(status="ok", service=request.app.state.settings.app_name)


@router.get("/db", response_model=HealthResponse)
def database_health(request: Request) -> HealthResponse:
    try:
        with request.app.state.engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        raise HTTPException(status_code=503, detail="database unavailable") from exc
    return HealthResponse(status="ok", service=request.app.state.settings.app_name)
