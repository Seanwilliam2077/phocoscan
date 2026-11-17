# syntax=docker/dockerfile:1
FROM node:24-bookworm-slim

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8787 \
    DATA_DIR=/var/lib/pocketworld/data \
    POCKETWORLD_CONFIG=/var/lib/pocketworld/.local-config.json

WORKDIR /app/server
COPY --chown=node:node server/package.json server/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# Explicit code-only allowlist: captures, local credentials and test fixtures
# must never enter the image, even if the build context changes later.
COPY --chown=node:node server/index.mjs server/admin.mjs ./
COPY --chown=node:node server/src/ ./src/
RUN mkdir -p /var/lib/pocketworld/data /var/lib/pocketworld/operator && chown -R node:node /var/lib/pocketworld

USER node
VOLUME ["/var/lib/pocketworld"]
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["node", "--input-type=module", "-e", "const r=await fetch('http://127.0.0.1:8787/health',{signal:AbortSignal.timeout(4000)});if(!r.ok||!(await r.json()).ok)process.exit(1)"]
CMD ["node", "index.mjs"]
