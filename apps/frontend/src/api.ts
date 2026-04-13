declare global {
  interface Window {
    __APP_CONFIG__?: { backendUrl: string };
  }
}

const backendUrl = window.__APP_CONFIG__?.backendUrl ?? "http://localhost:3000";

export async function fetchHello(): Promise<{ message: string }> {
  const res = await fetch(`${backendUrl}/api/hello`);
  if (!res.ok) throw new Error(`hello: ${res.status}`);
  return res.json();
}

export async function fetchInfo(): Promise<{
  pod: string;
  release: string;
  version: string;
  uptime: number;
}> {
  const res = await fetch(`${backendUrl}/api/info`);
  if (!res.ok) throw new Error(`info: ${res.status}`);
  return res.json();
}
