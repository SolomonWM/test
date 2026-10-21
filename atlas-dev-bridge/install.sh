#!/bin/bash
# Public, generic installer for a root-capable development MCP bridge.
# Review before running as root. This bridge is NOT a sandbox.
# Credentials are supplied privately at runtime; never paste them into chat.
set -euo pipefail
set +x
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ $(uname -sm) == 'Linux x86_64' ]] || { echo 'Linux x86_64 required.' >&2; exit 1; }
for cmd in curl python3 sha256sum mktemp bash; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
# Keep staging files on failure for inspection. Never remove installation/backups.
WORK=$(mktemp -d /tmp/atlas-dev-bridge-bootstrap.XXXXXXXX)
trap 'printf "Bootstrap staging directory (private): %s\n" "$WORK" >&2' EXIT
cd -- "$WORK"
printf 'Downloading checksum-pinned official tunnel-client v0.0.16...\n'
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --retry 3 --connect-timeout 30 --max-time 600 \
  --output tunnel-client.zip \
  https://github.com/openai/tunnel-client/releases/download/v0.0.16/tunnel-client-v0.0.16-linux-amd64.zip
printf '%s  %s\n' d60cdba019bce451bcc3a15478cc5b9cb11270b049f5b56ea39a80b517f8b117 tunnel-client.zip | sha256sum -c -
# Extract the complete verified distribution, including its companion and licenses.
python3 - <<'ATLAS_EXTRACT_PY'
from pathlib import PurePosixPath
import stat
import zipfile
with zipfile.ZipFile('tunnel-client.zip') as archive:
    for member in archive.infolist():
        path = PurePosixPath(member.filename)
        mode = member.external_attr >> 16
        if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(mode):
            raise SystemExit('Unsafe archive member; installation stopped')
    archive.extractall('.')
ATLAS_EXTRACT_PY
cat > install.sh <<'ATLAS_EMBEDDED_FILE_0_END'
#!/bin/bash
set -euo pipefail
set +x
umask 077
trap 'echo "Installation interrupted/failed. Inspect partial files under /opt/atlas-dev-bridge; preserve any /var/lib/atlas-dev-bridge backups. See README rollback before retry." >&2' ERR
cd -- "$(dirname -- "$0")"
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ $(uname -sm) == 'Linux x86_64' ]] || { echo 'Linux x86_64 required.' >&2; exit 1; }
for cmd in python3 systemctl pgrep sha256sum install; do command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }; done
python3 -c 'import sys; assert sys.version_info >= (3,10), "Python >=3.10 required"'
[[ -d /run/systemd/system ]] || { echo 'systemd must be the active init system.' >&2; exit 1; }
if pgrep -x tunnel-client >/dev/null; then
  echo 'Stop the existing foreground tunnel with Ctrl+C, then rerun. No overlapping tunnel clients allowed.' >&2
  exit 1
fi
for path in /opt/atlas-dev-bridge /etc/atlas-dev-bridge /var/lib/atlas-dev-bridge /etc/systemd/system/atlas-dev-bridge.service; do
  [[ ! -e "$path" && ! -L "$path" ]] || { echo "Refusing to overwrite existing installation: $path" >&2; exit 1; }
done
sha256sum -c SHA256SUMS
TUNNEL_ID=${1:-${CONTROL_PLANE_TUNNEL_ID:-}}
if [[ -z "$TUNNEL_ID" ]]; then read -r -p 'Existing tunnel ID (not a secret): ' TUNNEL_ID; fi
[[ "$TUNNEL_ID" =~ ^tunnel_[A-Za-z0-9_-]+$ ]] || { echo 'Invalid tunnel ID.' >&2; exit 1; }
# Never put a key in arguments, command history, output, or the service file.
KEY=${CONTROL_PLANE_API_KEY:-}
export -n KEY
unset CONTROL_PLANE_API_KEY OPENAI_API_KEY
if [[ -z "$KEY" ]]; then read -r -s -p 'Existing control-plane API key (hidden): ' KEY; printf '\n'; fi
[[ -n "$KEY" ]] || { echo 'Empty key; canceled.' >&2; exit 1; }
install -d -m 700 /opt/atlas-dev-bridge
python3 -m venv /opt/atlas-dev-bridge/venv || { echo 'Python venv unavailable. Install the distribution python3-venv package, then remove the incomplete /opt/atlas-dev-bridge directory and retry.' >&2; exit 1; }
/opt/atlas-dev-bridge/venv/bin/pip install --disable-pip-version-check -r requirements.txt
install -m 600 server.py requirements.txt test_bridge.py /opt/atlas-dev-bridge/
install -m 700 launch-mcp.sh tunnel-client cloudflared /opt/atlas-dev-bridge/
install -m 600 cloudflared-manifest.json LICENSE NOTICE *licenses.txt *.spdx.json /opt/atlas-dev-bridge/
# Exercise real MCP locally before storing credentials or enabling service.
(cd /opt/atlas-dev-bridge && ./venv/bin/python -m unittest -q test_bridge.py)
install -d -m 700 /etc/atlas-dev-bridge /var/lib/atlas-dev-bridge
printf '%s' "$KEY" > /etc/atlas-dev-bridge/control-plane.key
unset KEY CONTROL_PLANE_API_KEY OPENAI_API_KEY
cat > /etc/systemd/system/atlas-dev-bridge.service <<EOF
[Unit]
Description=Atlas root development MCP over OpenAI Secure Tunnel
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
UMask=0077
WorkingDirectory=/opt/atlas-dev-bridge
RuntimeDirectory=atlas-dev-bridge
RuntimeDirectoryMode=0700
ExecStart=/opt/atlas-dev-bridge/tunnel-client run --control-plane.tunnel-id=${TUNNEL_ID} --control-plane.api-key=file:/etc/atlas-dev-bridge/control-plane.key --mcp.command=/opt/atlas-dev-bridge/launch-mcp.sh --health.unix-socket=/run/atlas-dev-bridge/health.sock --log.format=json --log.level=warn
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
chmod 600 /etc/systemd/system/atlas-dev-bridge.service
systemctl daemon-reload
systemctl enable --now atlas-dev-bridge.service
systemctl is-active atlas-dev-bridge.service
printf '\nInstalled. Next: refresh/reconnect the existing ChatGPT custom plugin so it discovers the seven tools.\n'
printf 'Service active does NOT prove the end-to-end tunnel works; run the documented checks.\n'
ATLAS_EMBEDDED_FILE_0_END
cat > server.py <<'ATLAS_EMBEDDED_FILE_1_END'
"""Root-capable development MCP. No network listener. Not a sandbox."""
import asyncio
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import selectors
import socket
import signal
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from mcp.server.fastmcp import FastMCP

os.umask(0o077)
STATE = Path(os.environ.get('BRIDGE_STATE', '/var/lib/atlas-dev-bridge'))
STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
BACKUPS = STATE / 'backups'
BACKUPS.mkdir(exist_ok=True, mode=0o700)
LOCK = threading.Lock()
MCP = FastMCP('Contabo development bridge')
ENV = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
       'HOME': '/root', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'}
LIMIT = 262144

@contextmanager
def exclusive():
    if not LOCK.acquire(blocking=False):
        raise RuntimeError('A command or edit is in progress; poll the job and retry later')
    try:
        yield
    finally:
        LOCK.release()

def digest(data):
    return hashlib.sha256(data).hexdigest()

def audit(action, phase, action_id, **metadata):
    # Never record command, path, file contents, output or environment values.
    event = {'time_ns': time.time_ns(), 'action': action, 'phase': phase,
             'id': action_id, **metadata}
    with (STATE / 'audit.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')
        f.flush()
        os.fsync(f.fileno())

def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def start(action):
    action_id = uuid.uuid4().hex
    audit(action, 'started', action_id)
    return action_id

@MCP.tool()
def list_directory(path: str, limit: int = 200, offset: int = 0) -> dict:
    """List a directory, with pagination. Names may be sensitive; do not read secrets."""
    if not 1 <= limit <= 1000 or offset < 0:
        raise ValueError('Invalid pagination')
    action_id = start('list_directory')
    names = sorted(os.listdir(path))
    audit('list_directory', 'finished', action_id, count=min(limit, max(0, len(names)-offset)))
    return {'names': names[offset:offset+limit], 'total': len(names), 'action_id': action_id}

@MCP.tool()
def read_file(path: str, offset: int = 0, max_bytes: int = 65536) -> dict:
    """Read UTF-8 text in bounded chunks. Avoid credentials and secret files."""
    if not 1 <= max_bytes <= LIMIT or offset < 0:
        raise ValueError('Invalid read size')
    action_id = start('read_file')
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise ValueError('Regular files only')
        f.seek(offset)
        data = f.read(max_bytes)
    audit('read_file', 'finished', action_id, bytes=len(data))
    return {'text': data.decode('utf-8', errors='replace'), 'bytes': len(data),
            'next_offset': offset + len(data), 'chunk_sha256': digest(data), 'action_id': action_id}

@MCP.tool()
def write_file(path: str, content: str, expected_sha256: str) -> dict:
    """Atomic UTF-8 write, backup first. Supply whole-file SHA-256, or 'new' for creation.
    Rejects symlinks and hard links. Not for special files or files needing ACL/xattr preservation.
    """
    data = content.encode('utf-8')
    if len(data) > 4*1024*1024:
        raise ValueError('Maximum write is 4 MiB')
    with exclusive():
        action_id = start('write_file')
        p = Path(path)
        old = None
        if p.is_symlink():
            raise ValueError('Symlink writes refused')
        if p.exists():
            st = p.stat()
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise ValueError('Single-link regular files only')
            if st.st_size > 16*1024*1024:
                raise ValueError('Existing file exceeds backup limit')
            old = p.read_bytes()
            if digest(old) != expected_sha256:
                raise ValueError('Hash mismatch: reread before editing')
            # Fail rather than silently drop special metadata.
            if os.listxattr(p):
                raise ValueError('Extended attributes require a manual preservation plan')
        elif expected_sha256 != 'new':
            raise ValueError('Use expected_sha256=new for a new file')
        backup = None
        if old is not None:
            backup = BACKUPS / action_id
            backup.write_bytes(old)
            with backup.open('rb') as f:
                os.fsync(f.fileno())
            metadata = {'uid': st.st_uid, 'gid': st.st_gid, 'mode': stat.S_IMODE(st.st_mode),
                        'atime_ns': st.st_atime_ns, 'mtime_ns': st.st_mtime_ns}
            meta = BACKUPS / (action_id + '.metadata.json')
            meta.write_text(json.dumps(metadata))
            with meta.open('rb') as f:
                os.fsync(f.fileno())
            sync_dir(BACKUPS)
        fd, tmp = tempfile.mkstemp(prefix='.atlas-edit-', dir=p.parent)
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(data)
                f.flush()
                if old is not None:
                    os.fchown(f.fileno(), st.st_uid, st.st_gid)
                    os.fchmod(f.fileno(), stat.S_IMODE(st.st_mode))
                os.fsync(f.fileno())
            if p.is_symlink() or (old is not None and p.read_bytes() != old) or (old is None and p.exists()):
                raise ValueError('File changed during write; refusing replacement')
            os.replace(tmp, p)
            sync_dir(p.parent)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        audit('write_file', 'finished', action_id, bytes=len(data), backed_up=backup is not None)
        return {'action_id': action_id, 'sha256': digest(data), 'backup': str(backup) if backup else None}

def _run_command(command: str, cwd: str, timeout_seconds: int = 60, max_output_bytes: int = 65536) -> dict:
    """Run an authorized bash command as the bridge user, with combined output and exit status.
    FULL ROOT POWER when bridge is root. No sandbox. Commands can bypass file backups.
    Back up affected files explicitly before shell edits. Never print secrets.
    Timeout/output overflow kills process group. No interactive input; no persistent jobs.
    """
    if not 1 <= timeout_seconds <= 3600 or not 1 <= max_output_bytes <= LIMIT:
        raise ValueError('Invalid execution limits')
    with exclusive():
        action_id = start('run_command')
        p = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', command],
                             cwd=cwd, env=ENV, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(p.stdout, selectors.EVENT_READ)
        output = bytearray()
        stop_reason = None
        deadline = time.monotonic() + timeout_seconds
        try:
            while selector.get_map():
                if time.monotonic() >= deadline:
                    stop_reason = 'timeout'
                    break
                for key, _ in selector.select(min(0.2, max(0, deadline-time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    room = max_output_bytes - len(output)
                    output.extend(chunk[:room])
                    if len(chunk) > room:
                        stop_reason = 'output_limit'
                        break
                if stop_reason:
                    break
            if stop_reason:
                os.killpg(p.pid, signal.SIGKILL)
            remaining = max(0.01, deadline-time.monotonic())
            try:
                p.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                stop_reason = 'timeout'
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
        finally:
            selector.close()
            p.stdout.close()
            # Clean ordinary descendants even after the parent shell exited.
            # A deliberate setsid escape is possible: this is not a sandbox.
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
        audit('run_command', 'finished', action_id, exit_code=p.returncode,
              output_bytes=len(output), stop_reason=stop_reason)
        return {'action_id': action_id, 'exit_code': p.returncode,
                'output': output.decode('utf-8', errors='replace'), 'stop_reason': stop_reason}

@MCP.tool()
async def run_command(command: str, cwd: str, timeout_seconds: int = 60, max_output_bytes: int = 65536) -> dict:
    """Run authorized root bash command. NO SANDBOX; no automatic backups for shell edits.
    Returns bounded output/exit status. Prefer start_job for long builds; never print secrets.
    """
    return await asyncio.to_thread(_run_command, command, cwd, timeout_seconds, max_output_bytes)

@MCP.tool()
def server_info() -> dict:
    """Report bridge identity and limits; never credentials."""
    return {'name': 'atlas-dev-bridge', 'version': '1.0.0', 'hostname': socket.gethostname(),
            'uid': os.getuid(), 'pid': os.getpid(), 'transport': 'stdio',
            'source_sha256': digest(Path(__file__).read_bytes()),
            'job_timeout_max_seconds': 3600, 'sandboxed': False}

JOBS = {}
JOBS_LOCK = threading.Lock()

@MCP.tool()
def start_job(command: str, cwd: str, timeout_seconds: int = 300) -> dict:
    """Start a bounded build/test command and return immediately. Poll using job_status.
    Same root risks as run_command. Jobs are in memory and stop on service shutdown.
    """
    if not 1 <= timeout_seconds <= 3600:
        raise ValueError('Timeout must be 1..3600 seconds')
    with JOBS_LOCK:
        if any(v['status'] == 'running' for v in JOBS.values()):
            raise ValueError('One background job at a time; poll existing job first')
        if len(JOBS) >= 100:
            oldest = next(iter(JOBS))
            del JOBS[oldest]
        job_id = uuid.uuid4().hex
        JOBS[job_id] = {'status': 'running'}
    def work():
        try:
            result = _run_command(command, cwd, timeout_seconds, LIMIT)
            value = {'status': 'finished', 'result': result}
        except Exception as exc:
            value = {'status': 'failed', 'error_type': type(exc).__name__}
        with JOBS_LOCK:
            JOBS[job_id] = value
    threading.Thread(target=work, daemon=True).start()
    return {'job_id': job_id, 'status': 'running'}

@MCP.tool()
def job_status(job_id: str) -> dict:
    """Get job state and final bounded output. Up to 100 jobs retained until restart."""
    with JOBS_LOCK:
        if job_id not in JOBS:
            raise ValueError('Unknown job ID or bridge restarted')
        return dict(JOBS[job_id])

if __name__ == '__main__':
    MCP.run(transport='stdio')
ATLAS_EMBEDDED_FILE_1_END
cat > test_bridge.py <<'ATLAS_EMBEDDED_FILE_2_END'
import asyncio, hashlib, json, os, sys, tempfile, unittest, subprocess
from pathlib import Path
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

class BridgeTest(unittest.IsolatedAsyncioTestCase):
 async def test_roundtrip(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp); state=root/'state'; fixture=root/'file.txt'; fixture.write_text('old'); fixture.chmod(0o640)
   params=StdioServerParameters(command=sys.executable,args=[str(Path(__file__).with_name('server.py'))],env={'BRIDGE_STATE':str(state),'CONTROL_PLANE_API_KEY':'FAKE_SECRET_TEST_ONLY'})
   async with stdio_client(params) as (read,write):
    async with ClientSession(read,write) as s:
     await s.initialize()
     names={t.name for t in (await s.list_tools()).tools}
     self.assertEqual(names, {'list_directory','read_file','write_file','run_command','start_job','job_status','server_info'})
     async def call(name, **args):
      r=await s.call_tool(name,args)
      self.assertFalse(r.isError, r)
      return json.loads(r.content[0].text)
     r=await call('read_file',path=str(fixture)); self.assertEqual(r['text'],'old')
     r=await call('write_file',path=str(fixture),content='new',expected_sha256=hashlib.sha256(b'old').hexdigest())
     self.assertEqual(Path(r['backup']).read_text(),'old');self.assertEqual(fixture.read_text(),'new')
     self.assertEqual(fixture.stat().st_mode & 0o777,0o640)
     metadata=json.loads(Path(r['backup']+'.metadata.json').read_text());self.assertEqual(metadata['mode'],0o640)
     r=await s.call_tool('write_file',{'path':str(fixture),'content':'bad','expected_sha256':'wrong'});self.assertTrue(r.isError)
     link=root/'link';link.symlink_to(fixture)
     r=await s.call_tool('write_file',{'path':str(link),'content':'bad','expected_sha256':'new'});self.assertTrue(r.isError)
     r=await call('run_command',command='printf "%s" "${CONTROL_PLANE_API_KEY-unset}"; printf err >&2; exit 7',cwd=tmp)
     self.assertEqual(r['output'],'unseterr');self.assertEqual(r['exit_code'],7)
     r=await call('run_command',command='sleep 10',cwd=tmp,timeout_seconds=1);self.assertEqual(r['stop_reason'],'timeout')
     r=await call('run_command',command='yes A',cwd=tmp,max_output_bytes=20);self.assertEqual(r['stop_reason'],'output_limit');self.assertEqual(len(r['output']),20)
     r=await call('start_job',command='printf finished',cwd=tmp)
     for _ in range(100):
      result=await call('job_status',job_id=r['job_id'])
      if result['status']!='running': break
      await asyncio.sleep(.02)
     self.assertEqual(result['result']['output'],'finished')
     busy=await call('start_job',command='sleep 1',cwd=tmp)
     await asyncio.sleep(.05)
     blocked=await s.call_tool('run_command',{'command':'true','cwd':tmp})
     self.assertTrue(blocked.isError)
     busy_state=await call('job_status',job_id=busy['job_id']);self.assertEqual(busy_state['status'],'running')
     await asyncio.sleep(1.1)
     await call('list_directory',path=tmp)
     identity=await call('server_info');self.assertFalse(identity['sandboxed'])
     fifo=root/'fifo';os.mkfifo(fifo)
     special=await s.call_tool('read_file',{'path':str(fifo)});self.assertTrue(special.isError)
   audit=(state/'audit.jsonl').read_text()
   for forbidden in ['FAKE_SECRET','printf','file.txt','unseterr','finished']:
    if forbidden == 'finished': continue
    self.assertNotIn(forbidden,audit)
   self.assertEqual(state.stat().st_mode & 0o777,0o700)

class CLIConfigTest(unittest.TestCase):
 def test_log_flag_pair(self):
  base=Path(__file__).parent
  binary=base/'tunnel-client'
  self.assertTrue(binary.is_file(), 'Official tunnel-client must be adjacent for CLI validation')
  installer=base/'install.sh'
  if installer.exists():
   unit_line=next(line for line in installer.read_text().splitlines() if line.startswith('ExecStart='))
   self.assertIn('--log.format=json --log.level=warn', unit_line)
  with tempfile.TemporaryDirectory() as tmp:
   key=Path(tmp)/'dummy.key';key.write_text('sk-not-a-real-key')
   args=[str(binary),'doctor','--control-plane.tunnel-id=tunnel_0123456789abcdef0123456789abcdef',
         '--control-plane.api-key=file:'+str(key),'--mcp.command=/bin/true',
         '--health.unix-socket='+tmp+'/health.sock','--log.level=warn']
   env={'PATH':'/usr/bin:/bin','HOME':tmp}
   bad=subprocess.run(args,env=env,text=True,capture_output=True,timeout=10)
   self.assertIn("log level requires 'struct-text' or 'json' log format",bad.stdout+bad.stderr)
   good=subprocess.run(args+['--log.format=json'],env=env,text=True,capture_output=True,timeout=10)
   output=good.stdout+good.stderr
   self.assertNotIn('FAILED_CHECKS config_validation',output)
   self.assertIn('mcp_command_executable   PASS',output)
   self.assertIn('stdio targets are not probed over the network',output)
   # doctor additionally tests a local health socket. This cloud sandbox forbids
   # sockets; that independent FAIL is expected here, not config acceptance.

if __name__=='__main__': unittest.main()
ATLAS_EMBEDDED_FILE_2_END
cat > requirements.txt <<'ATLAS_EMBEDDED_FILE_3_END'
mcp==1.29.0
ATLAS_EMBEDDED_FILE_3_END
cat > launch-mcp.sh <<'ATLAS_EMBEDDED_FILE_4_END'
#!/bin/sh
# Deliberately discard tunnel credentials and all other inherited environment.
exec /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 BRIDGE_STATE=/var/lib/atlas-dev-bridge /opt/atlas-dev-bridge/venv/bin/python /opt/atlas-dev-bridge/server.py
ATLAS_EMBEDDED_FILE_4_END
cat > SHA256SUMS <<'ATLAS_EMBEDDED_FILE_5_END'
2198ed2af4ba3a5a66268094e92bf309ff9b39798a2decf3a8f79c4a3bb8d9a5  server.py
9d7640963b3bc0fdfb745c3cdad592391b11c70a13817bbbeefb0986d550826d  launch-mcp.sh
b1a0e8947a80d3222c56a9b748ee0e4f7f19ce3273c76db72da57b0ff7b105ca  requirements.txt
ba5d700dfea9787a68c7bb449220afe44eb4d7b8e04091629841e68a0f13280d  test_bridge.py
01260ee973d5510861bc32979739561edd33869f99f9f8cd324f6d0da5b2e692  tunnel-client
4e3f48f0bfa1fda6f86d055c60064e50f5d776ff8c0f3c773ae6083000ccd6e9  cloudflared
80003d8a8f38d6a0bd74aabc096e9f99a6e8fad8ed4da699e26a8231fa453aa1  cloudflared-manifest.json
f4c1d7ba32ef5bcf5cf03e2eefec5825ebafedf50fa330a36700a49c605c1ef4  LICENSE
1364c020d86ecf948b78b7c655175032068203d13aece70fb0bfe112d7802dc2  NOTICE
fa2de0dd02c120d9d4283059fa3bd489666808b616c4b788610558b8fb4198e6  tunnel-client-v0.0.16-linux-amd64-licenses.txt
6e55f7d59863c7f0313d51c3da211c86ac068ac4cafa28713cf8004138d2a46b  tunnel-client-v0.0.16-linux-amd64.spdx.json
ATLAS_EMBEDDED_FILE_5_END
printf '%s  %s\n' 99d79b13da8e9491a8f2a2a5714142a1cee547407fbc1019f697b99ad937fa95 install.sh | sha256sum -c -
sha256sum -c SHA256SUMS
# No existing install is overwritten. On failure inspect partial /opt/atlas-dev-bridge.
# Preserve /var/lib/atlas-dev-bridge backups; do not blindly remove them.
# Stop/disable an installed service with: systemctl disable --now atlas-dev-bridge.service
# The tunnel and its account-side configuration are not deleted by this bootstrap.
bash install.sh "$@"
