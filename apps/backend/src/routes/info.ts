import { Router } from "express";
import { env } from "../env.js";

export const infoRouter = Router();

infoRouter.get("/api/info", (_req, res) => {
  res.json({
    pod: env.podName,
    release: env.releaseName,
    version: env.version,
    uptime: Math.round(process.uptime()),
  });
});

infoRouter.get("/api/health", (_req, res) => {
  res.status(200).send("ok");
});
