import { Router } from "express";
import { env } from "../env.js";

export const helloRouter = Router();

helloRouter.get("/api/hello", (_req, res) => {
  res.json({ message: `Hello from sandbox ${env.releaseName}` });
});
