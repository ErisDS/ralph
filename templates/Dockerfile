# Project-specific Ralph Dockerfile
# Extends ralph-base with your project's repo and dependencies

FROM ralph-base

# Build argument for cloning private repos
ARG GITHUB_TOKEN

# Clone your repository
# Replace with your repo URL (the token is used for private repos)
ARG REPO_URL=https://github.com/your-org/your-project.git
RUN if [ -n "$GITHUB_TOKEN" ]; then \
        git clone "https://${GITHUB_TOKEN}@github.com/your-org/your-project.git" /workspace ; \
    else \
        git clone "$REPO_URL" /workspace ; \
    fi \
    && git -C /workspace remote set-url origin "$REPO_URL"

WORKDIR /workspace

# Install dependencies (customize for your package manager)
# For pnpm:
RUN pnpm install --frozen-lockfile

# For npm:
# RUN npm ci

# For yarn:
# RUN yarn install --frozen-lockfile

# Optional: Pre-build the project for faster startup
RUN pnpm build || true

# Copy ralph config into the image
COPY . /ralph/

# Give ralph user ownership
RUN chown -R ralph:ralph /workspace /ralph

# Set home directory for ralph user
ENV HOME=/home/ralph

# Switch to non-root user
USER ralph

# Use the generic ralph entrypoint
ENTRYPOINT ["/usr/local/bin/ralph-entrypoint.sh"]
