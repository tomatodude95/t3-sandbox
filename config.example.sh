# shellcheck shell=bash
# sandbox.sh config. Copy to ~/.config/t3-sandbox/config.sh and uncomment what
# you need. It is sourced as bash. Environment variables override it.

# sbx binary: a name on PATH or an absolute path.
#SBX_BIN=sbx

# Host folder mounted read-only into every new sandbox. Unset = no mount.
#SKILLS_DIR="$HOME/skills"

# 1 = run 'sbx skills import --force' before every create/start, 0 = don't.
# Defaults to 1 when SKILLS_DIR is set, 0 otherwise.
#SKILLS_IMPORT=1

# First host port tried for opencode / t3-code sandboxes.
#BASE_PORT=8081
#T3_BASE_PORT=3773

# sbx agent names used for opencode and claude sandboxes.
#OPENCODE_IMAGE=opencode
#CLAUDE_IMAGE=claude

# kind:sandbox kit for t3-code sandboxes. Defaults to sbx-custom-kit/ next to
# sandbox.sh.
#T3CODE_KIT="$HOME/t3-code-sandbox/sbx-custom-kit"

# Comma-separated hosts allowed for every new sandbox, on top of your sbx
# policy preset ('sbx policy allow network --sandbox <name> ...'). Applied on
# create only; for existing sandboxes run that command yourself.
#NETWORK_ALLOW="api.example.com,*.example.org"
