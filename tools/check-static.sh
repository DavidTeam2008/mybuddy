#!/usr/bin/env bash
# Fast static guardrail. Run from anywhere; it resolves the repo root itself.
#
# Checks:
# - Domain does not import UI, speech, translation, persistence, or FoundationModels;
# - Domain does not reference type names declared in Services;
# - the old Conversation-owned Host path is gone;
# - no Xcode-generated DEVELOPMENT_TEAM or empty Localizable.xcstrings keys are added.
#
# This is intentionally a shell script with no third-party dependency.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failed=0
fail_check() {
    printf 'FAIL: %s\n' "$*" >&2
    failed=1
}

domain_files=()
while IFS= read -r -d '' file; do
    domain_files+=("$file")
done < <(find Duiyi/Domain -name '*.swift' -print0)

service_files=()
while IFS= read -r -d '' file; do
    service_files+=("$file")
done < <(find Duiyi/Services -name '*.swift' -print0)

if [[ ${#domain_files[@]} -gt 0 ]]; then
    banned_imports='SwiftUI|Speech|Translation|SwiftData|AVFoundation|FoundationModels'
    if grep -nE "^[[:space:]]*import[[:space:]]+(${banned_imports})([[:space:]]|$)" "${domain_files[@]}"; then
        fail_check "Domain must not import UI, speech, translation, persistence, or FoundationModels."
    fi
fi

extract_types() {
    grep -hE '^[[:space:]]*[^/]*(struct|class|enum|actor|protocol)[[:space:]]+[A-Za-z_]' "$@" \
        | grep -oE '(struct|class|enum|actor|protocol)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
        | awk '{print $2}' \
        | sort -u
}

if [[ ${#domain_files[@]} -gt 0 && ${#service_files[@]} -gt 0 ]]; then
    domain_types="$(extract_types "${domain_files[@]}")"
    service_types="$(extract_types "${service_files[@]}")"
    service_only="$(comm -23 \
        <(printf '%s\n' "$service_types") \
        <(printf '%s\n' "$domain_types"))"

    while IFS= read -r type_name; do
        [[ -z "$type_name" ]] && continue
        hits="$(grep -nE "(^|[^A-Za-z0-9_])${type_name}([^A-Za-z0-9_]|$)" "${domain_files[@]}" \
            | grep -vE ':[0-9]+:[[:space:]]*///?' || true)"
        if [[ -n "$hits" ]]; then
            printf 'FAIL: Domain references Services type %s:\n%s\n' "$type_name" "$hits" >&2
            failed=1
        fi
    done <<< "$service_only"
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
    old_host="$(git grep -n 'Features/Conversation/TranslationHostView' -- '*.swift' '*.md' '*.pbxproj' 2>/dev/null || true)"
    if [[ -n "$old_host" ]]; then
        printf 'FAIL: old Conversation-owned Host path is still referenced:\n%s\n' "$old_host" >&2
        failed=1
    fi

    team_change="$(git diff HEAD -- Duiyi.xcodeproj/project.pbxproj \
        | grep -E '^\+.*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]' || true)"
    if [[ -n "$team_change" ]]; then
        printf 'FAIL: Xcode changed DEVELOPMENT_TEAM; restore it before committing:\n%s\n' "$team_change" >&2
        failed=1
    fi

    empty_key="$(git diff HEAD -- Duiyi/Localizable.xcstrings \
        | grep -E '^\+[[:space:]]*""[[:space:]]*:[[:space:]]*\{' || true)"
    if [[ -n "$empty_key" ]]; then
        printf 'FAIL: Localizable.xcstrings gained an empty key; restore Xcode extraction noise:\n%s\n' "$empty_key" >&2
        failed=1
    fi
fi

if [[ "$failed" -ne 0 ]]; then
    printf 'check-static: FAIL\n' >&2
    exit 1
fi

printf 'check-static: PASS\n'
