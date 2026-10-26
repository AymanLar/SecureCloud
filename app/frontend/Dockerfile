FROM node:22-alpine AS builder

WORKDIR /app

ARG NEXT_PUBLIC_API_URL=http://localhost:8000
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# Keep only runtime dependencies in the shipped image: dev tooling (eslint,
# typescript, @types, eslint-config-next and its transitive deps) is build-only
# and must not ship. This also removes dev-only CVEs from the image scan.
RUN npm prune --omit=dev

FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs && adduser --system --uid 1001 nextjs

COPY --from=builder /app/package.json /app/package-lock.json ./
COPY --from=builder /app/next.config.ts /app/tsconfig.json ./
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules

RUN chown -R nextjs:nodejs /app

# Bundled npm is build-time-only; the runtime starts `next` with plain Node.
# Removing it also clears its unpatchable npm-tooling CVEs from the image.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npx && \
    rm -f /usr/local/bin/npm

USER nextjs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -qO- http://127.0.0.1:3000/ > /dev/null || exit 1

CMD ["./node_modules/.bin/next", "start"]
