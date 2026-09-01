# Unset every AUTH and MODEL-ROUTING variable config-loader.sh cmd_export would have
# set for a provider model, so a leftover parent-shell env cannot send HOST_CLAUDE opus
# to z.ai. Deliberately NOT the whole cmd_export set: CLAUDE_MESH_PROVIDER_KIND,
# CLAUDE_MESH_DATA_DIR and CLAUDE_MESH_TIMEOUT_* stay, because none of them can route a
# request — PROVIDER_KIND is read only in the provider branch, and the HOST_CLAUDE branch
# takes its timeouts from `get-runtime` instead. Keep this list in step with the auth and
# routing exports only; test-host-claude-env.sh pins it.
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
      ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
      CLAUDE_CODE_ATTRIBUTION_HEADER CLAUDE_CODE_AUTO_COMPACT_WINDOW
