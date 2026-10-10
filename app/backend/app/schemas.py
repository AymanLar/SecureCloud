from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field

Environment = Literal["development", "staging", "production"]
DeploymentStatus = Literal["pending", "succeeded", "failed"]


class UserCreate(BaseModel):
    email: EmailStr
    full_name: str = Field(min_length=1, max_length=120)


class UserRead(UserCreate):
    id: int
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class ProjectCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    owner_id: int = Field(gt=0)


class ProjectRead(ProjectCreate):
    id: int
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class DeploymentCreate(BaseModel):
    project_id: int = Field(gt=0)
    environment: Environment


class DeploymentRead(DeploymentCreate):
    id: int
    status: DeploymentStatus
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class HealthResponse(BaseModel):
    status: str
    service: str
