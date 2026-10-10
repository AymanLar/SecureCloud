from fastapi.testclient import TestClient


def test_create_user(client: TestClient, user_payload: dict) -> None:
    response = client.post("/api/users", json=user_payload)
    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["email"] == "alice@example.com"
    assert body["full_name"] == "Alice"
    assert "created_at" in body


def test_list_users(client: TestClient, created_user: dict) -> None:
    response = client.get("/api/users")
    assert response.status_code == 200
    assert [user["id"] for user in response.json()] == [created_user["id"]]


def test_duplicate_email_rejected(client: TestClient, user_payload: dict) -> None:
    assert client.post("/api/users", json=user_payload).status_code == 201
    response = client.post("/api/users", json=user_payload)
    assert response.status_code == 409
    assert response.json()["detail"] == "email already registered"


def test_invalid_email_rejected(client: TestClient) -> None:
    response = client.post("/api/users", json={"email": "not-an-email", "full_name": "Bob"})
    assert response.status_code == 422


def test_empty_full_name_rejected(client: TestClient) -> None:
    response = client.post("/api/users", json={"email": "bob@example.com", "full_name": ""})
    assert response.status_code == 422
