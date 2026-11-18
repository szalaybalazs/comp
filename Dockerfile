# =============================================================================
# STAGE 1: Dependencies - Install and cache workspace dependencies
# =============================================================================
FROM oven/bun:1.4.4 AS deps

WORKDIR /app

# Copy workspace configuration
COPY package.json bun.lock bunfig.toml ./

# Include all workspace packages
COPY packages ./packages
COPY apps ./apps



# Install all dependencies
RUN PRISMA_SKIP_POSTINSTALL_GENERATE=true bun install --ignore-scripts

# =============================================================================
# STAGE 2: Migrator / Seeder - Prisma 7 + local schema, migrations and seed
# =============================================================================
FROM oven/bun:1.4.4 AS migrator

WORKDIR /app/packages/db

# Local schema, migrations, seed data and Prisma config from the workspace
COPY packages/db/prisma ./prisma
COPY packages/db/prisma.config.ts ./prisma.config.ts
COPY packages/db/scripts/generate-prisma-client-js.js ./scripts/

# Minimal runtime package.json, pinned to the versions packages/db uses
RUN echo '{"name":"migrator","private":true,"scripts":{"migrate":"prisma migrate deploy","seed":"bun prisma/seed/seed.ts"},"dependencies":{"prisma":"7.6.0","@prisma/client":"7.6.0","@prisma/adapter-pg":"7.6.0","dotenv":"^16.4.5","zod":"^4.3.6"}}' > package.json

RUN bun install

# Generate the full Prisma client into node_modules/@prisma/client (used by seed.ts)
RUN node scripts/generate-prisma-client-js.js

# Fail the build if the seed's dependencies or generated models are missing
RUN bun -e "require('@prisma/adapter-pg'); require('zod'); \
    const { Prisma } = require('@prisma/client'); \
    if (!Prisma.ModelName.FrameworkEditorFramework) throw new Error('Prisma client has no models');"

# Default: apply migrations (prisma.config.ts reads DATABASE_URL).
# Seed with: bun prisma/seed/seed.ts
CMD ["bunx", "prisma", "migrate", "deploy"]

# =============================================================================
# STAGE 3: App Builder
# =============================================================================
FROM deps AS app-builder

WORKDIR /app

# Copy all source code needed for build
COPY packages ./packages
COPY apps/app ./apps/app

# Bring in node_modules for build and prisma prebuild
COPY --from=deps /app/node_modules ./node_modules

# Pre-combine schemas and generate the Prisma client into
# node_modules/@prisma/client. The deps stage ran `bun install` with
# `--ignore-scripts` so packages/db's postinstall was skipped; we run
# it explicitly here so `next build` can resolve the generated runtime
# + types when it imports @prisma/client.
#
# The app resolves @trycompai/{db,auth,billing,company} through their
# package.json exports, which point at dist/ — build them before next build.
# `bun run build` in packages/db generates the Prisma client, compiles
# dist/ and writes dist/schema.prisma.
RUN cd packages/db && bun run build
RUN cd packages/auth && bun run build
RUN cd packages/billing && bun run build
RUN cd packages/company && bun run build

# Ensure Next build has required public env at build-time
ARG NEXT_PUBLIC_BETTER_AUTH_URL
ARG NEXT_PUBLIC_PORTAL_URL
ARG NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_POSTHOG_HOST
ARG NEXT_PUBLIC_IS_DUB_ENABLED
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_BETTER_AUTH_URL=$NEXT_PUBLIC_BETTER_AUTH_URL \
    NEXT_PUBLIC_PORTAL_URL=$NEXT_PUBLIC_PORTAL_URL \
    NEXT_PUBLIC_POSTHOG_KEY=$NEXT_PUBLIC_POSTHOG_KEY \
    NEXT_PUBLIC_POSTHOG_HOST=$NEXT_PUBLIC_POSTHOG_HOST \
    NEXT_PUBLIC_IS_DUB_ENABLED=$NEXT_PUBLIC_IS_DUB_ENABLED \
    NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production \
    NEXT_OUTPUT_STANDALONE=true \
    NODE_OPTIONS=--max_old_space_size=6144

# Build the app
# Model .prisma files are gitignored in apps/app/prisma/schema; copy them in
# from packages/db so `prisma generate` emits a client with all models
RUN cd apps/app && bun run db:getschema
RUN cd apps/app && SKIP_ENV_VALIDATION=true bun run build:docker

# =============================================================================
# STAGE 4: App Production
# =============================================================================
FROM node:22.23.4-alpine AS app

WORKDIR /app

# Copy Next standalone output
COPY --from=app-builder /app/apps/app/.next/standalone ./
COPY --from=app-builder /app/apps/app/.next/static ./apps/app/.next/static
COPY --from=app-builder /app/apps/app/public ./apps/app/public

EXPOSE 3000
CMD ["node", "apps/app/server.js"]

# =============================================================================
# STAGE 5: Portal Builder
# =============================================================================
FROM deps AS portal-builder

WORKDIR /app

# Copy all source code needed for build
COPY packages ./packages
COPY apps/portal ./apps/portal

# Bring in node_modules for build and prisma prebuild
COPY --from=deps /app/node_modules ./node_modules

# Build the workspace packages the portal resolves via dist/ exports
# (db also generates the Prisma client and writes dist/schema.prisma)
RUN cd packages/db && bun run build
RUN cd packages/auth && bun run build
RUN cd packages/company && bun run build

RUN cp packages/db/dist/schema.prisma \
    apps/portal/prisma/schema.prisma

# Ensure Next build has required public env at build-time
ARG NEXT_PUBLIC_BETTER_AUTH_URL
ENV NEXT_PUBLIC_BETTER_AUTH_URL=$NEXT_PUBLIC_BETTER_AUTH_URL \
    NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production \
    NEXT_OUTPUT_STANDALONE=true \
    NODE_OPTIONS=--max_old_space_size=6144

# Build the portal
# Model .prisma files are gitignored in apps/portal/prisma/schema; copy them in
# from packages/db so `prisma generate` emits a client with all models
RUN cd apps/portal && bun run db:getschema
RUN cd apps/portal && SKIP_ENV_VALIDATION=true bun run build:docker

# =============================================================================
# STAGE 6: Portal Production
# =============================================================================
FROM node:22.23.4-alpine AS portal

WORKDIR /app

# Copy Next standalone output for portal
COPY --from=portal-builder /app/apps/portal/.next/standalone ./
COPY --from=portal-builder /app/apps/portal/.next/static ./apps/portal/.next/static
COPY --from=portal-builder /app/apps/portal/public ./apps/portal/public

EXPOSE 3000
CMD ["node", "apps/portal/server.js"]

# (Trigger.dev hosted; no local runner stage)
