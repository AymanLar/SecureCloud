import os

os.environ.setdefault("DATABASE_URL", "sqlite:///:memory:")

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture()
def client() -> TestClient:
    settings = Settings(database_url="sqlite:///:memory:", cors_origins="http://localhost:3000")
    app = create_app(settings)
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture()
def user_payload() -> dict:
    return {"email": "alice@example.com", "full_name": "Alice"}


@pytest.fixture()
def created_user(client: TestClient, user_payload: dict) -> dict:
    response = client.post("/api/users", json=user_payload)
    assert response.status_code == 201
    return response.json()


@pytest.fixture()
def created_project(client: TestClient, created_user: dict) -> dict:
    payload = {"name": "web-app", "description": "demo project", "owner_id": created_user["id"]}
    response = client.post("/api/projects", json=payload)
    assert response.status_code == 201
    return response.json()
