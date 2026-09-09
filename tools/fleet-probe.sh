#!/usr/bin/env bash
# fleet-probe.sh — Ground-truth probe of all known model endpoints.
# Outputs JSON for comparison against `ModelStatus status --json`.
set -euo pipefail

TIMEOUT=3
M4_HOST="${M4_HOST:-macmini-m4-pro.local}"

json_or_null() {
    local url="$1"
    local result
    result=$(curl -s --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT + 2))" "$url" 2>/dev/null) || true
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "null"
    fi
}

probe_ollama() {
    local label="$1" host="$2" port="${3:-11434}"
    local ps models
    ps=$(json_or_null "http://${host}:${port}/api/ps")
    models=$(json_or_null "http://${host}:${port}/api/tags")
    python3 -c "
import json, sys
label = '$label'
ps_raw = '''$ps'''
tags_raw = '''$models'''
ps = json.loads(ps_raw) if ps_raw != 'null' else None
tags = json.loads(tags_raw) if tags_raw != 'null' else None
result = {
    'name': label,
    'type': 'ollama',
    'url': 'http://${host}:${port}',
    'reachable': ps is not None,
    'loaded_models': [],
    'available_count': 0,
    'total_vram_bytes': 0,
}
if ps and 'models' in ps:
    for m in ps['models']:
        result['loaded_models'].append({
            'name': m.get('name','?'),
            'vram_bytes': m.get('size_vram', 0),
            'expires_at': m.get('expires_at'),
        })
    result['total_vram_bytes'] = sum(m.get('size_vram',0) for m in ps['models'])
if tags and 'models' in tags:
    result['available_count'] = len(tags['models'])
print(json.dumps(result))
"
}

probe_openai_compat() {
    local label="$1" host="$2" port="$3" provider_hint="${4:-openai}"
    local models health
    models=$(json_or_null "http://${host}:${port}/v1/models")
    health=$(json_or_null "http://${host}:${port}/health")
    python3 -c "
import json
label = '$label'
models_raw = '''$models'''
health_raw = '''$health'''
models = json.loads(models_raw) if models_raw != 'null' else None
health = json.loads(health_raw) if health_raw != 'null' else None
result = {
    'name': label,
    'type': '$provider_hint',
    'url': 'http://${host}:${port}',
    'reachable': models is not None or health is not None,
    'loaded_models': [],
    'available_count': 0,
    'health': health,
}
if models and 'data' in models:
    for m in models['data']:
        mid = m.get('id','?')
        result['loaded_models'].append({
            'name': mid,
            'owned_by': m.get('owned_by',''),
        })
    result['available_count'] = len(models['data'])
print(json.dumps(result))
"
}

probe_health_only() {
    local label="$1" host="$2" port="$3"
    local health
    health=$(json_or_null "http://${host}:${port}/health")
    python3 -c "
import json
label = '$label'
raw = '''$health'''
h = json.loads(raw) if raw != 'null' else None
result = {
    'name': label,
    'type': 'health-only',
    'url': 'http://${host}:${port}',
    'reachable': h is not None,
    'health': h,
    'model': h.get('model') if h else None,
}
print(json.dumps(result))
"
}

probe_gpu_arbiter() {
    local host="${1:-127.0.0.1}" port="${2:-8077}"
    local status
    status=$(json_or_null "http://${host}:${port}/status")
    python3 -c "
import json
raw = '''$status'''
s = json.loads(raw) if raw != 'null' else None
result = {
    'name': 'GPU Arbiter',
    'type': 'gpu-arbiter',
    'url': 'http://${host}:${port}',
    'reachable': s is not None,
    'resident': s.get('resident') if s else None,
    'pending': s.get('pending') if s else None,
    'queue_len': len(s.get('queue',[])) if s else 0,
}
print(json.dumps(result))
"
}

# --- Main ---
echo "{"
echo '  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
echo '  "ground_truth": ['

# Studio endpoints
probe_ollama "Studio Ollama" "127.0.0.1" 11434
echo ","
probe_openai_compat "Studio MLX" "127.0.0.1" 8080 "mlx"
echo ","
probe_health_only "Studio NuExtract" "127.0.0.1" 8091
echo ","
probe_gpu_arbiter "127.0.0.1" 8077
echo ","

# M4 Pro endpoints
probe_ollama "M4 Pro Ollama" "$M4_HOST" 11434
echo ","
probe_openai_compat "M4 Pro MLX" "$M4_HOST" 8080 "mlx"

echo ""
echo "  ],"

# ModelStatus CLI view
echo '  "modelstatus_view": '
/Users/lucasmullikin/projects/OllamaStatus/build/ModelStatus.app/Contents/MacOS/ModelStatus status --json 2>/dev/null || echo '[]'

echo "}"
