from fastapi.testclient import TestClient


def test_create_deployment(client: TestClient, created_project: dict) -> None:
    payload = {"project_id": created_project["id"], "environment": "production"}
    response = client.post("/api/deployments", json=payload)
    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["project_id"] == created_project["id"]
    assert body["environment"] == "production"
    assert body["status"] == "pending"


def test_create_deployment_unknown_project(client: TestClient) -> None:
    response = client.post("/api/deployments", json={"project_id": 9999, "environment": "staging"})
    assert response.status_code == 404
    assert response.json()["detail"] == "project not found"


def test_invalid_environment_rejected(client: TestClient, created_project: dict) -> None:
    response = client.post(
        "/api/deployments",
        json={"project_id": created_project["id"], "environment": "moon"},
    )
    assert response.status_code == 422


def test_list_deployments(client: TestClient, created_project: dict) -> None:
    payload = {"project_id": created_project["id"], "environment": "development"}
    created = client.post("/api/deployments", json=payload).json()
    response = client.get("/api/deployments")
    assert response.status_code == 200
    assert [deployment["id"] for deployment in response.json()] == [created["id"]]


def test_get_deployment(client: TestClient, created_project: dict) -> None:
    payload = {"project_id": created_project["id"], "environment": "staging"}
    created = client.post("/api/deployments", json=payload).json()
    response = client.get(f"/api/deployments/{created['id']}")
    assert response.status_code == 200
    assert response.json()["environment"] == "staging"


def test_get_deployment_not_found(client: TestClient) -> None:
    response = client.get("/api/deployments/424242")
    assert response.status_code == 404
    assert response.json()["detail"] == "deployment not found"
