#!/usr/bin/env bash

set -euo pipefail

API_URL="${MAESTRO_API_URL:-https://dashboard.maestrodeck.cloud}"

TIMEOUT="${TIMEOUT-1800}"

if [[ -z "${API_KEY:-}" ]]; then
    echo "::error::api_key is required"
    exit 1
fi

PLATFORM="$(echo "${PLATFORM:-}" | tr '[:upper:]' '[:lower:]')"
VISUAL_STRICT="$(echo "${VISUAL_STRICT:-false}" | tr '[:upper:]' '[:lower:]')"
case "$PLATFORM" in
    ios | android | web) ;;
    *)
        echo "::error::platform must be 'ios', 'android' or 'web' (got: '$PLATFORM')"
        exit 1
        ;;
esac

# Le web n'a pas de fichier applicatif : la cible est une URL. Pour ios et
# android le contrat est inchangé, l'app reste obligatoire.
if [[ "$PLATFORM" == "web" ]]; then
    if [[ -z "${URL:-}" ]]; then
        echo "::error::url is required when platform is 'web'"
        exit 1
    fi
else
    if [[ -z "${APP:-}" ]]; then
        echo "::error::app is required when platform is '$PLATFORM'"
        exit 1
    fi
    if [[ ! -f "$APP" ]]; then
        echo "::error::app file not found: $APP"
        exit 1
    fi
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

yaml_names=()
for f in "${FLOW_FILES[@]}"; do yaml_names+=("$(basename "$f")"); done
yamls_json="$(printf '%s\n' "${yaml_names[@]}" | jq -R '{name: .}' | jq -s '.')"

BANK_FILES=()
if [[ -n "${BANK_PATH:-}" ]]; then
    if [[ ! -d "$BANK_PATH" ]]; then
        echo "::error::bank_path not found: $BANK_PATH"
        exit 1
    fi
    while IFS= read -r f; do BANK_FILES+=("$f"); done \
        < <(find "$BANK_PATH" -maxdepth 1 -type f -iname '*.png' | sort)
    if [[ ${#BANK_FILES[@]} -eq 0 ]]; then
        echo "::warning::bank_path set but no .png files found: $BANK_PATH"
    fi
fi

if [[ ${#BANK_FILES[@]} -gt 200 ]]; then
    echo "::error::bank_path has ${#BANK_FILES[@]} images, the platform accepts at most 200"
    exit 1
fi

declare -A seen_sanitized
bank_names=()
bank_sizes=()
for f in "${BANK_FILES[@]}"; do
    name="$(basename "$f")"
    size="$(wc -c <"$f" | tr -d ' ')"
    if [[ "$size" -gt 10485760 ]]; then
        echo "::error::bank image exceeds 10 MB: $name"
        exit 1
    fi
    sanitized="$(echo -n "$name" | sed -E 's/[^a-zA-Z0-9._-]/_/g')"
    if [[ -n "${seen_sanitized[$sanitized]:-}" ]]; then
        echo "::error::bank images collide once sanitized: $name and ${seen_sanitized[$sanitized]}"
        exit 1
    fi
    seen_sanitized[$sanitized]="$name"
    bank_names+=("$name")
    bank_sizes+=("$size")
done

bank_json="[]"
if [[ ${#bank_names[@]} -gt 0 ]]; then
    bank_json="$(
        for i in "${!bank_names[@]}"; do
            jq -n --arg name "${bank_names[$i]}" --argjson size "${bank_sizes[$i]}" '{name: $name, size: $size}'
        done | jq -s '.'
    )"
    echo "Bank: ${bank_names[*]}"
fi

# La cible du job : une URL pour le web, le nom du fichier applicatif sinon.
if [[ "$PLATFORM" == "web" ]]; then
    init_target="$(jq -n --arg url "$URL" '{url: $url}')"
else
    init_target="$(jq -n --arg appname "$(basename "$APP")" '{apk: {name: $appname}}')"
fi

req="$(jq -n \
    --arg platform "$PLATFORM" \
    --argjson target "$init_target" \
    --argjson yamls "$yamls_json" \
    --argjson bank "$bank_json" \
    '{platform: $platform} + $target + {yamls: $yamls}
     + (if ($bank | length) > 0 then {bank: $bank} else {} end)')"

echo "Initializing job..."
init_resp="$(curl -fsS -X POST "$API_URL/api/jobs/init" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$req")"

JOB_ID="$(echo "$init_resp" | jq -r '.jobId')"
report_url="$API_URL/runs/$JOB_ID"
echo "Created job: $JOB_ID"

apk_gs=""
if [[ "$PLATFORM" == "web" ]]; then
    echo "Target: $URL"
else
    echo "Uploading app..."
    apk_url="$(echo "$init_resp" | jq -r '.apk.uploadUrl')"
    apk_gs="$(echo "$init_resp" | jq -r '.apk.gsPath')"
    curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "$APP" "$apk_url" >/dev/null
fi

echo "Uploading flows..."
yaml_count="$(echo "$init_resp" | jq '.yamls | length')"
for i in $(seq 0 $((yaml_count - 1))); do
    url="$(echo "$init_resp" | jq -r ".yamls[$i].uploadUrl")"
    curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "${FLOW_FILES[$i]}" "$url" >/dev/null
done

bank_count="$(echo "$init_resp" | jq '.bank // [] | length')"
if [[ "$bank_count" -gt 0 ]]; then
    echo "Uploading bank images..."
    for i in $(seq 0 $((bank_count - 1))); do
        b_url="$(echo "$init_resp" | jq -r ".bank[$i].uploadUrl")"
        curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "${BANK_FILES[$i]}" "$b_url" >/dev/null
    done
fi

echo "Finalizing job..."
yaml_paths_json="$(echo "$init_resp" | jq '[.yamls[].gsPath]')"
bank_paths_json="$(echo "$init_resp" | jq -c '[.bank[]?.gsPath]')"
if [[ "$PLATFORM" == "web" ]]; then
    fin_target="$(jq -n --arg url "$URL" '{url: $url}')"
else
    fin_target="$(jq -n --arg apkPath "$apk_gs" '{apkPath: $apkPath}')"
fi

fin_req="$(jq -n \
    --arg jobId "$JOB_ID" \
    --argjson target "$fin_target" \
    --argjson yamlPaths "$yaml_paths_json" \
    --arg platform "$PLATFORM" \
    --arg email "${EMAIL:-}" \
    --arg appName "${APP_NAME:-}" \
    --argjson bankPaths "$bank_paths_json" \
    --argjson visualStrict "$([[ "$VISUAL_STRICT" == "true" ]] && echo true || echo false)" \
    '{jobId: $jobId} + $target + {yamlPaths: $yamlPaths, platform: $platform}
     + (if $email == "" then {} else {email: $email} end)
     + (if $appName == "" then {} else {appName: $appName} end)
     + (if ($bankPaths | length) > 0 then {bankPaths: $bankPaths, visualStrict: $visualStrict} else {} end)')"

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

visual_json="$(echo "$poll" | jq -c '.visual // null' 2>/dev/null || echo null)"
visual_changed=""
visual_missing=""
if [[ "$visual_json" != "null" ]]; then
    visual_changed="$(echo "$visual_json" | jq -r '.changed')"
    visual_missing="$(echo "$visual_json" | jq -r '.missing')"
fi

{
    echo "job_id=$JOB_ID"
    echo "status=$status"
    echo "report_url=$report_url"
    echo "visual_changed=$visual_changed"
    echo "visual_missing=$visual_missing"
} >> "${GITHUB_OUTPUT:-/dev/null}"

summary="$(echo "$poll" | jq -r 'if .summary then "\(.summary.passed)/\(.summary.total) passed, \(.summary.failed) failed" else "no summary" end' 2>/dev/null || echo "no summary")"
echo "Result: $status ($summary)"
if [[ "$visual_json" != "null" ]]; then
    echo "Visual: $(echo "$visual_json" | jq -r '"\(.matched)/\(.total) matched, \(.changed) changed, \(.missing) missing"')"
fi
echo "Report: $report_url"

if [[ "$status" != "passed" ]]; then
    echo "::error::run $status"
    exit 1
fi

if [[ "$VISUAL_STRICT" == "true" && "$visual_json" != "null" && $((visual_changed + visual_missing)) -gt 0 ]]; then
    echo "::error::visual regression detected ($visual_changed changed, $visual_missing missing) with visual_strict enabled"
    exit 1
fi

exit 0
