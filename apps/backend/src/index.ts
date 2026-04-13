import express from "express";
import cors from "cors";
import { env } from "./env.js";
import { helloRouter } from "./routes/hello.js";
import { infoRouter } from "./routes/info.js";

const app = express();
app.use(cors({ origin: env.corsOrigin }));
app.use(helloRouter);
app.use(infoRouter);

app.listen(env.port, () => {
  console.log(
    `backend listening on :${env.port} release=${env.releaseName} pod=${env.podName}`
  );
});
