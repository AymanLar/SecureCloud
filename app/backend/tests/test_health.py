from fastapi.testclient import TestClient


def test_health(client: TestClient) -> None:
    response = client.get("/api/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["service"] == "SecureCloud API"


def test_database_health(client: TestClient) -> None:
    response = client.get("/api/health/db")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
