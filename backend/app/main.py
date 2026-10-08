import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.exc import SQLAlchemyError

from app.config import Settings, get_settings
from app.database import create_db_engine, create_session_factory
from app.models import Base
from app.routers import deployments, health, projects, users

logger = logging.getLogger("securecloud")

DB_STARTUP_ATTEMPTS = 10
DB_STARTUP_DELAY_SECONDS = 3


def _create_tables(engine) -> None:
    last_error: SQLAlchemyError | None = None
    for _ in range(DB_STARTUP_ATTEMPTS):
        try:
            Base.metadata.create_all(engine)
            return
        except SQLAlchemyError as exc:
            last_error = exc
            logger.warning("database not ready yet, retrying: %s", exc)
            time.sleep(DB_STARTUP_DELAY_SECONDS)
    raise last_error


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        _create_tables(app.state.engine)
        logger.info("database schema is ready")
        yield

    app = FastAPI(title=settings.app_name, version="1.0.0", lifespan=lifespan)
    app.state.settings = settings
    app.state.engine = create_db_engine(settings.database_url)
    app.state.session_factory = create_session_factory(app.state.engine)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_methods=["GET", "POST"],
        allow_headers=["*"],
    )

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        logger.exception("Unhandled error on %s", request.url.path)
        return JSONResponse(status_code=500, content={"detail": "internal server error"})

    app.include_router(health.router)
    app.include_router(users.router)
    app.include_router(projects.router)
    app.include_router(deployments.router)
    return app


app = create_app()
