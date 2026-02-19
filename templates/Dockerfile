# syntax=docker/dockerfile:1
# Project-specific Ralph Dockerfile
# Extends ralph-base with your project's repo and dependencies

ARG RALPH_BASE_IMAGE=ralph-base
FROM ${RALPH_BASE_IMAGE}

ARG PACKAGE_MANAGER=pnpm
ARG INSTALL_CMD=""
ARG BUILD_CMD=""

# Clone your repository using BuildKit secret mount (token not baked into layers)
# Replace with your repo URL
ARG REPO_URL=https://github.com/your-org/your-project.git
RUN --mount=type=secret,id=github_token \
    if [ -f /run/secrets/github_token ]; then \
        GITHUB_TOKEN=$(cat /run/secrets/github_token) && \
        git clone "https://${GITHUB_TOKEN}@github.com/your-org/your-project.git" /workspace ; \
    else \
        git clone "$REPO_URL" /workspace ; \
    fi \
    && git -C /workspace remote set-url origin "$REPO_URL"

WORKDIR /workspace

# Install dependencies (customize for your package manager)
RUN if [ -n "$INSTALL_CMD" ]; then \
        eval "$INSTALL_CMD"; \
    else \
        case "$PACKAGE_MANAGER" in \
            pnpm) CI=true pnpm install --frozen-lockfile ;; \
            yarn) CI=true yarn install --frozen-lockfile ;; \
            npm) npm ci ;; \
            *) echo "Unknown package manager: $PACKAGE_MANAGER"; exit 1 ;; \
        esac; \
    fi

# Optional: Pre-build the project for faster startup
RUN if [ -n "$BUILD_CMD" ]; then \
        eval "$BUILD_CMD"; \
    else \
        case "$PACKAGE_MANAGER" in \
            pnpm) pnpm build || true ;; \
            yarn) yarn build || true ;; \
            npm) npm run build || true ;; \
            *) echo "Unknown package manager: $PACKAGE_MANAGER"; exit 1 ;; \
        esac; \
    fi

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
