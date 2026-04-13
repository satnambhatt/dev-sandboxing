import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import request from "supertest";

test("GET /api/info returns pod, release, version, uptime", async () => {
  // Set env BEFORE importing the module, because env.ts captures
  // process.env at import time as a module-level constant.
  process.env.POD_NAME = "app-pr-123-backend-abc";
  process.env.RELEASE_NAME = "pr-123";
  process.env.VERSION = "sha-deadbeef";
  const { infoRouter } = await import("../src/routes/info.js");
  const app = express();
  app.use(infoRouter);
  const res = await request(app).get("/api/info");
  assert.equal(res.status, 200);
  assert.equal(res.body.pod, "app-pr-123-backend-abc");
  assert.equal(res.body.release, "pr-123");
  assert.equal(res.body.version, "sha-deadbeef");
  assert.equal(typeof res.body.uptime, "number");
});

test("GET /api/health returns 200", async () => {
  const { infoRouter } = await import("../src/routes/info.js");
  const app = express();
  app.use(infoRouter);
  const res = await request(app).get("/api/health");
  assert.equal(res.status, 200);
});
