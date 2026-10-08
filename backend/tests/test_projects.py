from fastapi.testclient import TestClient


def test_create_project(client: TestClient, created_user: dict) -> None:
    payload = {"name": "web-app", "description": "demo project", "owner_id": created_user["id"]}
    response = client.post("/api/projects", json=payload)
    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["name"] == "web-app"
    assert body["owner_id"] == created_user["id"]


def test_create_project_unknown_owner(client: TestClient) -> None:
    response = client.post(
        "/api/projects", json={"name": "orphan", "owner_id": 9999}
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "owner not found"


def test_list_projects(client: TestClient, created_project: dict) -> None:
    response = client.get("/api/projects")
    assert response.status_code == 200
    assert [project["id"] for project in response.json()] == [created_project["id"]]


def test_get_project(client: TestClient, created_project: dict) -> None:
    response = client.get(f"/api/projects/{created_project['id']}")
    assert response.status_code == 200
    assert response.json()["name"] == "web-app"


def test_get_project_not_found(client: TestClient) -> None:
    response = client.get("/api/projects/424242")
    assert response.status_code == 404
    assert response.json()["detail"] == "project not found"


def test_empty_project_name_rejected(client: TestClient, created_user: dict) -> None:
    response = client.post(
        "/api/projects", json={"name": "", "owner_id": created_user["id"]}
    )
    assert response.status_code == 422
