from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.deps import get_session
from app.models import Project, User
from app.schemas import ProjectCreate, ProjectRead

router = APIRouter(prefix="/api/projects", tags=["projects"])


@router.post("", response_model=ProjectRead, status_code=201)
def create_project(payload: ProjectCreate, db: Session = Depends(get_session)) -> Project:
    owner = db.get(User, payload.owner_id)
    if owner is None:
        raise HTTPException(status_code=404, detail="owner not found")
    project = Project(**payload.model_dump())
    db.add(project)
    db.flush()
    return project


@router.get("", response_model=list[ProjectRead])
def list_projects(
    db: Session = Depends(get_session),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[Project]:
    return list(db.scalars(select(Project).order_by(Project.id).limit(limit).offset(offset)))


@router.get("/{project_id}", response_model=ProjectRead)
def get_project(project_id: int, db: Session = Depends(get_session)) -> Project:
    project = db.get(Project, project_id)
    if project is None:
        raise HTTPException(status_code=404, detail="project not found")
    return project
