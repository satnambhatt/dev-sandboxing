import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import request from "supertest";

test("GET /api/hello returns greeting with release name", async () => {
  // Set env BEFORE importing the module, because env.ts captures
  // process.env at import time as a module-level constant.
  process.env.RELEASE_NAME = "pr-123";
  const { helloRouter } = await import("../src/routes/hello.js");
  const app = express();
  app.use(helloRouter);
  const res = await request(app).get("/api/hello");
  assert.equal(res.status, 200);
  assert.equal(res.body.message, "Hello from sandbox pr-123");
});
