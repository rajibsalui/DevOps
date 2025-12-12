FROM node:20-alpine

WORKDIR /var/www/express-app/

# Copy package files
COPY package*.json ./

# Install all dependencies (including dev dependencies for building)
RUN npm ci

# Copy source code and TypeScript config
COPY . .

# Build TypeScript to JavaScript
RUN npm run build

# Start the application
CMD ["node", "dist/index.js"]
