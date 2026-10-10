"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";

import {
  api,
  ApiError,
  Deployment,
  ENVIRONMENTS,
  Environment,
  Project,
  User,
} from "@/lib/api";

function errorMessage(err: unknown): string {
  return err instanceof ApiError ? err.message : "unexpected error";
}

export default function Dashboard() {
  const [users, setUsers] = useState<User[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [deployments, setDeployments] = useState<Deployment[]>([]);
  const [apiUp, setApiUp] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const [userEmail, setUserEmail] = useState("");
  const [userName, setUserName] = useState("");

  const [projectName, setProjectName] = useState("");
  const [projectDescription, setProjectDescription] = useState("");
  const [projectOwnerId, setProjectOwnerId] = useState("");

  const [deploymentProjectId, setDeploymentProjectId] = useState("");
  const [deploymentEnvironment, setDeploymentEnvironment] = useState<Environment>("development");

  const refresh = useCallback(async () => {
    try {
      const [health, userData, projectData, deploymentData] = await Promise.all([
        api.health(),
        api.listUsers(),
        api.listProjects(),
        api.listDeployments(),
      ]);
      setApiUp(health.status === "ok");
      setUsers(userData);
      setProjects(projectData);
      setDeployments(deploymentData);
      setError(null);
    } catch (err) {
      setApiUp(false);
      setError(errorMessage(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const load = async () => {
      await refresh();
    };
    void load();
  }, [refresh]);

  async function run(action: () => Promise<void>) {
    try {
      await action();
      setError(null);
    } catch (err) {
      setError(errorMessage(err));
    }
  }

  function handleCreateUser(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void run(async () => {
      await api.createUser({ email: userEmail, full_name: userName });
      setUserEmail("");
      setUserName("");
      await refresh();
    });
  }

  function handleCreateProject(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void run(async () => {
      await api.createProject({
        name: projectName,
        description: projectDescription || null,
        owner_id: Number(projectOwnerId),
      });
      setProjectName("");
      setProjectDescription("");
      await refresh();
    });
  }

  function handleCreateDeployment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void run(async () => {
      await api.createDeployment({
        project_id: Number(deploymentProjectId),
        environment: deploymentEnvironment,
      });
      await refresh();
    });
  }

  const formatDate = (value: string) => new Date(value).toLocaleString();

  return (
    <main className="container">
      <header className="header">
        <div>
          <h1>SecureCloud</h1>
          <p className="subtitle">Cloud project and deployment management</p>
        </div>
        <span className={`badge ${apiUp ? "badge-ok" : "badge-err"}`}>
          {loading ? "connecting..." : apiUp ? "API online" : "API offline"}
        </span>
      </header>

      {error && <div className="error-banner">{error}</div>}

      <section className="card">
        <h2>Users</h2>
        <form className="form-row" onSubmit={handleCreateUser}>
          <input
            type="email"
            placeholder="email"
            value={userEmail}
            onChange={(event) => setUserEmail(event.target.value)}
            required
          />
          <input
            type="text"
            placeholder="full name"
            value={userName}
            onChange={(event) => setUserName(event.target.value)}
            required
            maxLength={120}
          />
          <button type="submit">Add user</button>
        </form>
        {users.length === 0 ? (
          <p className="empty">No users yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Email</th>
                <th>Name</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {users.map((user) => (
                <tr key={user.id}>
                  <td>{user.id}</td>
                  <td>{user.email}</td>
                  <td>{user.full_name}</td>
                  <td>{formatDate(user.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="card">
        <h2>Projects</h2>
        <form className="form-row" onSubmit={handleCreateProject}>
          <input
            type="text"
            placeholder="project name"
            value={projectName}
            onChange={(event) => setProjectName(event.target.value)}
            required
            maxLength={120}
          />
          <input
            type="text"
            placeholder="description (optional)"
            value={projectDescription}
            onChange={(event) => setProjectDescription(event.target.value)}
            maxLength={500}
          />
          <select
            value={projectOwnerId}
            onChange={(event) => setProjectOwnerId(event.target.value)}
            required
          >
            <option value="" disabled>
              owner
            </option>
            {users.map((user) => (
              <option key={user.id} value={user.id}>
                {user.full_name} ({user.email})
              </option>
            ))}
          </select>
          <button type="submit" disabled={users.length === 0}>
            Create project
          </button>
        </form>
        {projects.length === 0 ? (
          <p className="empty">No projects yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Description</th>
                <th>Owner</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {projects.map((project) => (
                <tr key={project.id}>
                  <td>{project.id}</td>
                  <td>{project.name}</td>
                  <td>{project.description ?? "-"}</td>
                  <td>{users.find((user) => user.id === project.owner_id)?.email ?? project.owner_id}</td>
                  <td>{formatDate(project.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="card">
        <h2>Deployments</h2>
        <form className="form-row" onSubmit={handleCreateDeployment}>
          <select
            value={deploymentProjectId}
            onChange={(event) => setDeploymentProjectId(event.target.value)}
            required
          >
            <option value="" disabled>
              project
            </option>
            {projects.map((project) => (
              <option key={project.id} value={project.id}>
                {project.name}
              </option>
            ))}
          </select>
          <select
            value={deploymentEnvironment}
            onChange={(event) => setDeploymentEnvironment(event.target.value as Environment)}
          >
            {ENVIRONMENTS.map((environment) => (
              <option key={environment} value={environment}>
                {environment}
              </option>
            ))}
          </select>
          <button type="submit" disabled={projects.length === 0}>
            Deploy
          </button>
        </form>
        {deployments.length === 0 ? (
          <p className="empty">No deployments yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Project</th>
                <th>Environment</th>
                <th>Status</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {deployments.map((deployment) => (
                <tr key={deployment.id}>
                  <td>{deployment.id}</td>
                  <td>
                    {projects.find((project) => project.id === deployment.project_id)?.name ??
                      deployment.project_id}
                  </td>
                  <td>{deployment.environment}</td>
                  <td>
                    <span className={`status status-${deployment.status}`}>{deployment.status}</span>
                  </td>
                  <td>{formatDate(deployment.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </main>
  );
}
