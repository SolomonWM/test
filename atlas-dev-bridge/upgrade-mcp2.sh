#!/bin/bash
# Transport-only compatibility repair. No keys, tunnel identifiers or remote calls.
set -euo pipefail
set +x
umask 077
unset CONTROL_PLANE_API_KEY OPENAI_API_KEY
BASE=/opt/atlas-dev-bridge
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -d "$BASE/venv" && -f "$BASE/server.py" && -f "$BASE/launch-mcp.sh" ]] || { echo 'Original bridge installation not found.' >&2; exit 1; }
[[ ! -e "$BASE/venv-v2" && ! -L "$BASE/venv-v2" ]] || { echo 'venv-v2 exists; inspect previous attempt rather than overwrite.' >&2; exit 1; }
# Refuse to overwrite user edits or an unexpected version.
printf '%s  %s\n' \
  2198ed2af4ba3a5a66268094e92bf309ff9b39798a2decf3a8f79c4a3bb8d9a5 "$BASE/server.py" \
  9d7640963b3bc0fdfb745c3cdad592391b11c70a13817bbbeefb0986d550826d "$BASE/launch-mcp.sh" | sha256sum -c -
STAGE=$(mktemp -d "$BASE/upgrade-mcp2.XXXXXX")
mkdir -m 700 "$STAGE/original"
cp -a "$BASE/server.py" "$BASE/launch-mcp.sh" "$STAGE/original/"
SWITCHED=0
on_error() {
  status=$?
  trap - ERR
  if [[ $SWITCHED == 1 ]]; then
    systemctl stop atlas-dev-bridge.service || true
    cp -a "$STAGE/original/server.py" "$BASE/server.py"
    cp -a "$STAGE/original/launch-mcp.sh" "$BASE/launch-mcp.sh"
    systemctl start atlas-dev-bridge.service || true
    echo 'Switch failed; restored original server and launcher. Old SDK remains available.' >&2
  fi
  echo "Repair did not complete. Preserved diagnostic/backup directory: $STAGE" >&2
  exit "$status"
}
trap on_error ERR
python3 -m venv "$BASE/venv-v2"
"$BASE/venv-v2/bin/pip" install --disable-pip-version-check 'mcp==2.3.0'
python3 - "$BASE" "$STAGE" <<'PY'
from pathlib import Path
import sys
base, stage=map(Path,sys.argv[1:])
s=(base/'server.py').read_text()
for old,new in [('from mcp.server.fastmcp import FastMCP','from mcp.server import MCPServer'),
                ('MCP = FastMCP(', 'MCP = MCPServer('),
                ("'version': '1.0.0'", "'version': '1.0.1'")]:
    assert s.count(old)==1, 'Unexpected source; refusing unsafe patch'
    s=s.replace(old,new)
(stage/'server.py').write_text(s)
launch=(base/'launch-mcp.sh').read_text()
assert launch.count('/venv/bin/python')==1
(stage/'launch-mcp.sh').write_text(launch.replace('/venv/bin/python','/venv-v2/bin/python'))
# Existing local fixture tests still exercise legacy initialized sessions.
t=(base/'test_bridge.py').read_text().replace('.isError','.is_error')
(stage/'test_bridge.py').write_text(t)
(stage/'tunnel-client').symlink_to(base/'tunnel-client')
PY
"$BASE/venv-v2/bin/python" -m py_compile "$STAGE/server.py"
(cd "$STAGE" && "$BASE/venv-v2/bin/python" -m unittest -q test_bridge.py)
# Exact self-contained modern stdio tools/call, without initialize, before switch.
"$BASE/venv-v2/bin/python" - "$STAGE/server.py" <<'PY'
import asyncio, json, os, sys, tempfile
async def smoke():
    with tempfile.TemporaryDirectory() as d:
        p=await asyncio.create_subprocess_exec(sys.executable,sys.argv[1],
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,env={**os.environ,'BRIDGE_STATE':d})
        try:
            request={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{
                'name':'server_info','arguments':{},'_meta':{
                'io.modelcontextprotocol/protocolVersion':'2026-07-28',
                'io.modelcontextprotocol/clientCapabilities':{}}}}
            p.stdin.write((json.dumps(request)+'\n').encode());await p.stdin.drain()
            response=json.loads(await asyncio.wait_for(p.stdout.readline(),10))
            assert 'error' not in response, 'Modern protocol request failed'
            info=json.loads(response['result']['content'][0]['text'])
            assert info['name']=='atlas-dev-bridge' and info['version']=='1.0.1'
            print('Modern stdio server_info smoke: PASS')
        finally:
            p.stdin.close()
            await asyncio.wait_for(p.wait(),5)
asyncio.run(smoke())
PY
# All tests have passed. Only now replace the running transport implementation.
systemctl stop atlas-dev-bridge.service
SWITCHED=1
install -m 600 "$STAGE/server.py" "$BASE/server.py"
install -m 700 "$STAGE/launch-mcp.sh" "$BASE/launch-mcp.sh"
systemctl start atlas-dev-bridge.service
systemctl is-active --quiet atlas-dev-bridge.service
SWITCHED=0
trap - ERR
printf 'Transport upgraded to official MCP SDK 2.3.0; bridge version 1.0.1.\n'
printf 'Original venv unchanged. Original server/launcher backups: %s/original\n' "$STAGE"
printf 'Next: verify server_info from ChatGPT. Service-active alone is not end-to-end proof.\n'
