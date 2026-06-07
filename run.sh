#!/usr/bin/env bash

set -euo pipefail

API_URL="${MAESTRO_API_URL:-https://dashboard.maestrodeck.cloud}"

TIMEOUT="${TIMEOUT-1800}"

if [[ -z "${API_KEY:-}" ]]; then
    echo "::error::api_key is required"
    exit 1
fi

PLATFORM="$(echo "${PLATFORM:-}" | tr '[:upper:]' '[:lower:]')"
if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "android" ]]; then
    echo "::error::platform must be 'ios' or 'android' (got: '$PLATFORM')"
    exit 1
fi
if [[ ! -f "$APP" ]]; then
    echo "::error::app file not found: $APP"
    exit 1
fi

FLOW_FILES=()
if [[ -d "$FLOW" ]]; then
    while IFS= read -r f; do FLOW_FILES+=("$f"); done \
        < <(find "$FLOW" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
else
    for f in $FLOW; do
        [[ -f "$f" ]] && FLOW_FILES+=("$f")
    done
fi
if [[ ${#FLOW_FILES[@]} -eq 0 ]]; then
    echo "::error::no flow files found for: $FLOW"
    exit 1
fi
echo "Flows: ${FLOW_FILES[*]}"

APP_NAME="$(basename "$APP")"

yaml_names=()
for f in "${FLOW_FILES[@]}"; do yaml_names+=("$(basename "$f")"); done
yamls_json="$(printf '%s\n' "${yaml_names[@]}" | jq -R '{name: .}' | jq -s '.')"

req="$(jq -n \
    --arg platform "$PLATFORM" \
    --arg appname "$APP_NAME" \
    --argjson yamls "$yamls_json" \
    '{platform: $platform, apk: {name: $appname}, yamls: $yamls}')"

echo "Initializing job..."
init_resp="$(curl -fsS -X POST "$API_URL/api/jobs/init" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$req")"

JOB_ID="$(echo "$init_resp" | jq -r '.jobId')"
report_url="$API_URL/runs/$JOB_ID"
echo "Created job: $JOB_ID"

echo "Uploading app..."
apk_url="$(echo "$init_resp" | jq -r '.apk.uploadUrl')"
apk_gs="$(echo "$init_resp" | jq -r '.apk.gsPath')"
curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "$APP" "$apk_url" >/dev/null

echo "Uploading flows..."
yaml_count="$(echo "$init_resp" | jq '.yamls | length')"
for i in $(seq 0 $((yaml_count - 1))); do
    url="$(echo "$init_resp" | jq -r ".yamls[$i].uploadUrl")"
    curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "${FLOW_FILES[$i]}" "$url" >/dev/null
done

echo "Finalizing job..."
yaml_paths_json="$(echo "$init_resp" | jq '[.yamls[].gsPath]')"
fin_req="$(jq -n \
    --arg jobId "$JOB_ID" \
    --arg apkPath "$apk_gs" \
    --argjson yamlPaths "$yaml_paths_json" \
    --arg platform "$PLATFORM" \
    --arg email "${EMAIL:-}" \
    '{jobId: $jobId, apkPath: $apkPath, yamlPaths: $yamlPaths, platform: $platform}
     + (if $email == "" then {} else {email: $email} end)')"

fin_resp="$(mktemp)"
fin_code="$(curl -sS -o "$fin_resp" -w '%{http_code}' -X POST "$API_URL/api/jobs/finalize" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$fin_req")"
if [[ "$fin_code" != "200" ]]; then
    msg="$(jq -r '.message // .error // "unknown error"' "$fin_resp" 2>/dev/null || echo "unknown error")"
    echo "::error::finalize failed (HTTP $fin_code): $msg"
    {
        echo "job_id=$JOB_ID"
        echo "status=error"
        echo "report_url=$report_url"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 1
fi
echo "Job submitted, waiting for result..."

deadline=$(( $(date +%s) + TIMEOUT ))
status="pending"
report_url="$API_URL/runs/$JOB_ID"
poll=""

while true; do
    poll="$(curl -fsS "$API_URL/api/jobs/$JOB_ID/status" -H "X-API-Key: $API_KEY" || true)"
    if [[ -n "$poll" ]]; then
        status="$(echo "$poll" | jq -r '.status' 2>/dev/null || echo "$status")"
        report_url="$(echo "$poll" | jq -r '.reportUrl' 2>/dev/null || echo "$report_url")"
        echo "status: $status"
        case "$status" in
            passed|failed|error) break ;;
        esac
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
        echo "::error::timed out after ${TIMEOUT}s waiting for result (last status: $status)"
        status="error"
        break
    fi
    sleep 5
done

{
    echo "job_id=$JOB_ID"
    echo "status=$status"
    echo "report_url=$report_url"
} >> "${GITHUB_OUTPUT:-/dev/null}"

summary="$(echo "$poll" | jq -r 'if .summary then "\(.summary.passed)/\(.summary.total) passed, \(.summary.failed) failed" else "no summary" end' 2>/dev/null || echo "no summary")"
echo "Result: $status ($summary)"
echo "Report: $report_url"

if [[ "$status" == "passed" ]]; then
    exit 0
fi
echo "::error::run $status"
exit 1
