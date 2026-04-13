import { useEffect, useState } from "react";
import { fetchHello, fetchInfo } from "./api";

type Info = Awaited<ReturnType<typeof fetchInfo>>;

export function App() {
  const [message, setMessage] = useState<string>("...");
  const [info, setInfo] = useState<Info | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchHello()
      .then((r) => setMessage(r.message))
      .catch((e) => setError(String(e)));
    fetchInfo()
      .then(setInfo)
      .catch((e) => setError(String(e)));
  }, []);

  return (
    <main style={{ fontFamily: "system-ui", padding: 32, maxWidth: 640 }}>
      <h1>App Sandbox</h1>

      <section style={card}>
        <h2>Hello</h2>
        <p>{message}</p>
      </section>

      <section style={card}>
        <h2>Sandbox Info</h2>
        {error && <p style={{ color: "crimson" }}>{error}</p>}
        {info ? (
          <ul>
            <li><b>Pod:</b> {info.pod}</li>
            <li><b>Release:</b> {info.release}</li>
            <li><b>Version:</b> {info.version}</li>
            <li><b>Uptime:</b> {info.uptime}s</li>
          </ul>
        ) : (
          !error && <p>loading…</p>
        )}
      </section>
    </main>
  );
}

const card: React.CSSProperties = {
  border: "1px solid #ddd",
  borderRadius: 8,
  padding: 16,
  marginTop: 16,
};
