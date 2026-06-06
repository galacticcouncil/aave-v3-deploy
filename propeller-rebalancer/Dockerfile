FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY index.mjs ./
# config via env: BOT_SEED, RPC, THRESHOLD, TARGET, MAX_PER_CYCLE, SLIPPAGE, INTERVAL
# persistent loop, live broadcast (BOT_SEED required)
CMD ["node", "index.mjs", "--live"]
