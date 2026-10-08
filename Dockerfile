FROM node:22-bookworm-slim

# python3/make/g++: node-pty (a t3 dependency) has no prebuilt binary for every
# platform (e.g. linux/arm64) and falls back to compiling from source via node-gyp.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 make g++ git ca-certificates curl ripgrep sudo tini \
    && rm -rf /var/lib/apt/lists/*

# Providers T3 Code drives, plus T3 Code itself. The Copilot CLI isn't
# driven by T3 Code yet; it's here for when it is.
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

# Anonymous volume: survives stop/start/restart/reboot of *this* container,
# gets removed automatically with it (`docker rm -v` / `docker run --rm`).
# Give it a named volume or bind mount explicitly if you want auth/state to
# outlive the container itself.
VOLUME /home/agent

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/workspace"]
