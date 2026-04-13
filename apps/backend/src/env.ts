export const env = {
  port: Number(process.env.PORT ?? 3000),
  podName: process.env.POD_NAME ?? "local",
  releaseName: process.env.RELEASE_NAME ?? "local",
  version: process.env.VERSION ?? "dev",
  corsOrigin: process.env.CORS_ORIGIN ?? "*",
};
