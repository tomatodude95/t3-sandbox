FROM node:22-bookworm-slim

# python3/make/g++: node-pty (a t3 dependency) compiles from source where it
# has no prebuilt binary (e.g. linux/arm64).
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 make g++ git ca-certificates curl ripgrep sudo tini \
    && rm -rf /var/lib/apt/lists/*

# T3 Code doesn't use the Copilot CLI yet.
RUN npm install -g \
        t3@latest \
        @anthropic-ai/claude-code \
        @openai/codex \
        opencode-ai \
        @github/copilot \
    && npm cache clean --force

RUN useradd --create-home --shell /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent

WORKDIR /workspace
RUN chown agent:agent /workspace
USER agent
ENV HOME=/home/agent

COPY --chown=agent:agent entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3773

# Removed with the container; mount a named volume to keep logins longer.
VOLUME /home/agent

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/workspace"]
