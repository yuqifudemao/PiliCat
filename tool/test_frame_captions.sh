#!/usr/bin/env bash
# Run against a booted Android emulator. The fixture contains no subtitle track.
set -euo pipefail
fixture_dir=$(mktemp -d)
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$fixture_dir"
}
trap cleanup EXIT
font=$(fc-match -f '%{file}' 'Noto Sans CJK SC')
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=704x396:r=10:d=4 \
  -vf "drawtext=fontfile='$font':text='今天是晴天':fontsize=39:fontcolor=white:x=(w-tw)/2:y=320:enable='lt(t,2)',drawtext=fontfile='$font':text='明天要下雨':fontsize=39:fontcolor=white:x=(w-tw)/2:y=320:enable='gte(t,2)'" \
  -an -c:v libx264 -threads 2 -g 10 -pix_fmt yuv420p \
  -movflags +frag_keyframe+empty_moov+default_base_moof+global_sidx -f mp4 "$fixture_dir/captions.m4s"

python3 -u - "$fixture_dir" <<'PY' &
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

video = (Path(sys.argv[1]) / 'captions.m4s').read_bytes()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if (self.path != '/captions.m4s' or
            'Mozilla/' not in self.headers.get('User-Agent', '') or
            self.headers.get('Referer', '').rstrip('/') != 'https://www.bilibili.com'):
            self.send_error(403)
            return
        header = self.headers.get('Range')
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', header or '')
        start = int(match[1]) if match else 0
        end = min(int(match[2]), len(video)-1) if match and match[2] else len(video)-1
        if not 0 <= start <= end:
            self.send_error(416)
            return
        self.send_response(206 if match else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end-start+1))
        if match:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(video)}')
        self.end_headers()
        self.wfile.write(video[start:end+1])

ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
PY
server_pid=$!
flutter test --reporter expanded -d emulator-5554 integration_test/frame_captions_test.dart
