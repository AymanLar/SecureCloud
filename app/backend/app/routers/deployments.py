from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.deps import get_session
from app.models import Deployment, Project
from app.schemas import DeploymentCreate, DeploymentRead

router = APIRouter(prefix="/api/deployments", tags=["deployments"])


@router.post("", response_model=DeploymentRead, status_code=201)
def create_deployment(payload: DeploymentCreate, db: Session = Depends(get_session)) -> Deployment:
    project = db.get(Project, payload.project_id)
    if project is None:
        raise HTTPException(status_code=404, detail="project not found")
    deployment = Deployment(**payload.model_dump())
    db.add(deployment)
    db.flush()
    return deployment


@router.get("", response_model=list[DeploymentRead])
def list_deployments(
    db: Session = Depends(get_session),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[Deployment]:
    return list(db.scalars(select(Deployment).order_by(Deployment.id).limit(limit).offset(offset)))


@router.get("/{deployment_id}", response_model=DeploymentRead)
def get_deployment(deployment_id: int, db: Session = Depends(get_session)) -> Deployment:
    deployment = db.get(Deployment, deployment_id)
    if deployment is None:
        raise HTTPException(status_code=404, detail="deployment not found")
    return deployment
