#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class EchoHandler(BaseHTTPRequestHandler):
    def _send_response(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length else ''

        response = {
            'method': self.command,
            'path': self.path,
            'headers': dict(self.headers),
            'body': body,
        }

        if body:
            try:
                response['json'] = json.loads(body)
            except:
                pass

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response, indent=2).encode())

    def do_GET(self): self._send_response()
    def do_POST(self): self._send_response()
    def do_PUT(self): self._send_response()
    def do_DELETE(self): self._send_response()
    def log_message(self, format, *args): print(f"[Echo] {args[0]}")

if __name__ == '__main__':
    port = 9090
    print(f'Echo server running on http://localhost:{port}')
    HTTPServer(('', port), EchoHandler).serve_forever()
