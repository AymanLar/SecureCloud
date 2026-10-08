export const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export const ENVIRONMENTS = ["development", "staging", "production"] as const;
export type Environment = (typeof ENVIRONMENTS)[number];

export type User = {
  id: number;
  email: string;
  full_name: string;
  created_at: string;
};

export type Project = {
  id: number;
  name: string;
  description: string | null;
  owner_id: number;
  created_at: string;
};

export type Deployment = {
  id: number;
  project_id: number;
  environment: Environment;
  status: string;
  created_at: string;
};

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${API_URL}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
      cache: "no-store",
    });
  } catch {
    throw new ApiError(0, `cannot reach API at ${API_URL}`);
  }

  if (!response.ok) {
    let detail = response.statusText || `HTTP ${response.status}`;
    try {
      const body = (await response.json()) as { detail?: unknown };
      if (typeof body.detail === "string") {
        detail = body.detail;
      } else if (body.detail) {
        detail = JSON.stringify(body.detail);
      }
    } catch {
      // keep statusText
    }
    throw new ApiError(response.status, detail);
  }

  return (await response.json()) as T;
}

export const api = {
  health: () => request<{ status: string; service: string }>("/api/health"),
  listUsers: () => request<User[]>("/api/users"),
  createUser: (payload: { email: string; full_name: string }) =>
    request<User>("/api/users", { method: "POST", body: JSON.stringify(payload) }),
  listProjects: () => request<Project[]>("/api/projects"),
  createProject: (payload: { name: string; description?: string | null; owner_id: number }) =>
    request<Project>("/api/projects", { method: "POST", body: JSON.stringify(payload) }),
  listDeployments: () => request<Deployment[]>("/api/deployments"),
  createDeployment: (payload: { project_id: number; environment: Environment }) =>
    request<Deployment>("/api/deployments", { method: "POST", body: JSON.stringify(payload) }),
};
