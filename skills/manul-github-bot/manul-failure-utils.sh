#!/usr/bin/env bash
# Shared sanitization for failure details before they reach GitHub or lifecycle logs.
# Keep this deliberately conservative: redact common credential fields and token formats,
# but preserve surrounding diagnostic context that is useful for debugging.
manul_redact_failure_details() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | sed -E \
    -e 's/(authorization[[:space:]]*:[[:space:]]*(bearer|basic)[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/((password|passwd|access[_-]?token|token|secret|api[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*)[^[:space:],;&]+/\1[REDACTED]/Ig' \
    -e 's/(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})/[REDACTED_GITHUB_TOKEN]/g' \
    -e 's/(sk-[A-Za-z0-9_-]{20,})/[REDACTED_API_KEY]/g' \
    -e 's/(Bearer[[:space:]]+)[-A-Za-z0-9._~+\/=]{8,}/\1[REDACTED]/Ig' \
    -e 's#(https?://[^:/@[:space:]]+:)[^@[:space:]]+@#\1[REDACTED]@#g')"
  printf '%s' "$value"
}
