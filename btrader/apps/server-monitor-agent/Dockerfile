FROM node:22-alpine AS build
WORKDIR /app

COPY package.json tsconfig.json ./
RUN npm install --ignore-scripts
RUN printf '%s\n' '{ "compilerOptions": { "target": "ES2022", "module": "commonjs", "moduleResolution": "node", "lib": ["ES2022"], "strict": true, "esModuleInterop": true, "skipLibCheck": true } }' > /tsconfig.base.json
COPY src ./src
RUN npx tsc -p tsconfig.json

FROM node:22-alpine
WORKDIR /app
COPY --from=build /app/dist ./dist

USER node
CMD ["node", "dist/main.js"]
