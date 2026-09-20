FROM node:22-alpine AS build
WORKDIR /app

COPY package.json tsconfig.json ./
RUN npm install --ignore-scripts
COPY src ./src
RUN npx tsc -p tsconfig.json

FROM node:22-alpine
WORKDIR /app
COPY --from=build /app/dist ./dist

USER node
CMD ["node", "dist/main.js"]
