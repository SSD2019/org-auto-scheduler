#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Org Auto Scheduler HTTP Bridge Server
Bridges HTTP REST API requests to an active Emacs daemon running org-auto-scheduler,
and serves the Android Progressive Web App.
"""

import argparse
import http.server
import json
import mimetypes
import os
import re
import socketserver
import subprocess
import sys
import urllib.parse
from typing import Any, Dict, Optional, Tuple

class EmacsBridge:
    @staticmethod
    def eval_elisp(expr: str) -> Tuple[bool, Any]:
        """Evaluate an elisp expression in the active Emacs daemon via emacsclient."""
        try:
            cmd = ["emacsclient", "-e", expr]
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=30
            )
            if proc.returncode != 0:
                err_msg = proc.stderr.strip() or proc.stdout.strip()
                return False, f"Emacs error: {err_msg}"
            
            raw_out = proc.stdout.strip()
            if not raw_out:
                return True, {}

            def decode_octal_utf8(s: str) -> str:
                def repl(m):
                    raw_bytes = bytearray()
                    for oct_str in re.findall(r"\\([0-7]{3})", m.group(0)):
                        raw_bytes.append(int(oct_str, 8))
                    return raw_bytes.decode("utf-8", errors="replace")
                return re.sub(r"(\\[0-7]{3})+", repl, s)

            fixed_out = decode_octal_utf8(raw_out)
            
            # Try to decode JSON
            try:
                val = json.loads(fixed_out)
                if isinstance(val, str):
                    try:
                        val2 = json.loads(decode_octal_utf8(val))
                        return True, val2
                    except json.JSONDecodeError:
                        return True, {"raw": val}
                return True, val
            except json.JSONDecodeError:
                # Raw text or lisp symbol
                return True, {"raw": raw_out}
        except subprocess.TimeoutExpired:
            return False, "Emacs evaluation timed out (30s)"
        except FileNotFoundError:
            return False, "emacsclient not found in PATH"
        except Exception as e:
            return False, f"Bridge error: {str(e)}"

class AutoSchedulerHandler(http.server.SimpleHTTPRequestHandler):
    server_token: str = ""
    static_dir: str = ""

    def _send_json(self, status_code: int, data: Any):
        response_bytes = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(response_bytes)))
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(response_bytes)

    def _send_error_json(self, status_code: int, message: str):
        self._send_json(status_code, {"status": "error", "message": message})

    def _add_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With")

    def _check_auth(self) -> bool:
        if not self.server_token:
            return True
        # Check header
        auth_header = self.headers.get("Authorization", "")
        if auth_header.startswith("Bearer ") and auth_header[7:] == self.server_token:
            return True
        # Check query param
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if qs.get("token", [""])[0] == self.server_token:
            return True
        return False

    def do_OPTIONS(self):
        self.send_response(204)
        self._add_cors_headers()
        self.end_headers()

    def do_GET(self):
        if not self._check_auth():
            self._send_error_json(401, "Unauthorized: invalid or missing token")
            return

        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path.rstrip("/")
        qs = urllib.parse.parse_qs(parsed_url.query)

        # Ensure server elisp module is loaded
        EmacsBridge.eval_elisp("(require 'org-auto-scheduler-server nil t)")

        if path == "/api/status":
            ok, res = EmacsBridge.eval_elisp("(org-auto-scheduler-api-status)")
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/agenda":
            date_str = qs.get("date", [""])[0]
            days_str = qs.get("days", ["1"])[0]
            try:
                days_count = int(days_str)
            except ValueError:
                days_count = 1

            elisp = f'(org-auto-scheduler-api-agenda "{date_str}" {days_count})'
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/review":
            force = "t" if qs.get("force", ["0"])[0] in ("1", "true") else "nil"
            ok, res = EmacsBridge.eval_elisp(f"(org-auto-scheduler-api-review-state {force})")
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path.startswith("/api/tasks/"):
            task_id = path[len("/api/tasks/"):].strip()
            if task_id:
                ok, res = EmacsBridge.eval_elisp(f'(org-auto-scheduler-api-get-task "{task_id}")')
                if ok:
                    self._send_json(200, res)
                else:
                    self._send_error_json(404, str(res))
                return

        if path == "/api/adherence":
            ok, res = EmacsBridge.eval_elisp("(org-auto-scheduler-api-adherence)")
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/insights":
            elisp = "(json-serialize (list :status \"ok\" :multipliers (if (boundp 'org-auto-scheduler-effort-multipliers) org-auto-scheduler-effort-multipliers '())))"
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        # Serve static assets from static_dir
        self._serve_static(parsed_url.path)

    def do_POST(self):
        if not self._check_auth():
            self._send_error_json(401, "Unauthorized: invalid or missing token")
            return

        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path.rstrip("/")

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {}

        EmacsBridge.eval_elisp("(require 'org-auto-scheduler-server nil t)")

        if path == "/api/schedule/run":
            elisp = "(progn (org-auto-scheduler-schedule-tasks) (json-serialize (list :status \"ok\" :message \"Scheduling completed successfully!\")))"
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/schedule/bump":
            task_id = payload.get("task_id", "")
            minutes = payload.get("minutes", 30)
            if not task_id:
                self._send_error_json(400, "Missing required field: task_id")
                return
            elisp = f'(org-auto-scheduler-api-bump-agenda "{task_id}" {minutes})'
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/review/action":
            action = payload.get("action", "")
            task_id = payload.get("task_id", "")
            arg_val = payload.get("arg", "")
            
            # Format elisp call
            arg_str = f'"{arg_val}"' if arg_val else "nil"
            task_id_str = f'"{task_id}"' if task_id else "nil"
            elisp = f'(org-auto-scheduler-api-review-action "{action}" {task_id_str} {arg_str})'
            
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path.startswith("/api/tasks/") and path.endswith("/edit"):
            task_id = path[len("/api/tasks/"): -len("/edit")].strip()
            # Escape JSON payload safely for elisp string
            payload_str = json.dumps(payload).replace('\\', '\\\\').replace('"', '\\"')
            elisp = f'(org-auto-scheduler-api-edit-task "{task_id}" "{payload_str}")'
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path.startswith("/api/tasks/") and path.endswith("/clock"):
            task_id = path[len("/api/tasks/"): -len("/clock")].strip()
            action = payload.get("action", "in")
            elisp = f'(org-auto-scheduler-api-clock "{task_id}" "{action}")'
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path.startswith("/api/tasks/") and path.endswith("/jump"):
            task_id = path[len("/api/tasks/"): -len("/jump")].strip()
            elisp = f'(org-auto-scheduler-api-jump "{task_id}")'
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/tasks/create":
            payload_str = json.dumps(payload).replace('\\', '\\\\').replace('"', '\\"')
            elisp = f'(org-auto-scheduler-api-create-task "{payload_str}")'
            ok, res = EmacsBridge.eval_elisp(elisp)
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        if path == "/api/adherence/snapshot":
            ok, res = EmacsBridge.eval_elisp("(org-auto-scheduler-api-snapshot)")
            if ok:
                self._send_json(200, res)
            else:
                self._send_error_json(500, str(res))
            return

        self._send_error_json(404, f"API endpoint not found: {path}")

    def _serve_static(self, req_path: str):
        if not self.static_dir or not os.path.isdir(self.static_dir):
            self._send_error_json(404, "Static directory not configured or not found")
            return

        clean_path = req_path.lstrip("/")
        if not clean_path or clean_path == "/":
            clean_path = "index.html"

        file_path = os.path.abspath(os.path.join(self.static_dir, clean_path))
        # Directory traversal prevention
        if not file_path.startswith(os.path.abspath(self.static_dir)):
            self._send_error_json(403, "Access denied")
            return

        # Fallback to index.html for SPA/PWA routes if file doesn't exist and has no dot
        if not os.path.exists(file_path):
            if "." not in os.path.basename(clean_path):
                file_path = os.path.join(self.static_dir, "index.html")
            else:
                self._send_error_json(404, "File not found")
                return

        if os.path.isdir(file_path):
            file_path = os.path.join(file_path, "index.html")

        if not os.path.exists(file_path):
            self._send_error_json(404, "File not found")
            return

        mime_type, _ = mimetypes.guess_type(file_path)
        if not mime_type:
            if file_path.endswith(".json"):
                mime_type = "application/json"
            elif file_path.endswith(".webmanifest"):
                mime_type = "application/manifest+json"
            else:
                mime_type = "application/octet-stream"

        try:
            with open(file_path, "rb") as f:
                content = f.read()

            self.send_response(200)
            self.send_header("Content-Type", f"{mime_type}; charset=utf-8" if "text" in mime_type or "json" in mime_type or "javascript" in mime_type else mime_type)
            self.send_header("Content-Length", str(len(content)))
            if file_path.endswith("sw.js"):
                self.send_header("Service-Worker-Allowed", "/")
                self.send_header("Cache-Control", "no-cache")
            elif "static" in file_path or file_path.endswith((".css", ".js", ".svg", ".png", ".jpg")):
                self.send_header("Cache-Control", "public, max-age=86400")
            else:
                self.send_header("Cache-Control", "no-cache")
            self._add_cors_headers()
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self._send_error_json(500, f"Error reading file: {str(e)}")


def run_server(host: str, port: int, static_dir: str, token: str = ""):
    AutoSchedulerHandler.static_dir = os.path.abspath(static_dir)
    AutoSchedulerHandler.server_token = token

    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server_address = (host, port)
    httpd = ThreadedHTTPServer(server_address, AutoSchedulerHandler)
    print(f"==================================================")
    print(f" Org Auto Scheduler HTTP Bridge Server")
    print(f" Listening on http://{host}:{port}")
    print(f" Serving Android PWA from: {AutoSchedulerHandler.static_dir}")
    if token:
        print(f" Authentication: Enabled (Bearer token required)")
    else:
        print(f" Authentication: Disabled (Open on network)")
    print(f"==================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Org Auto Scheduler Mobile Server")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8989, help="Port to bind (default: 8989)")
    parser.add_argument("--static-dir", default="./android-app", help="Path to static web app directory")
    parser.add_argument("--token", default="", help="Optional authentication token")
    args = parser.parse_args()

    run_server(args.host, args.port, args.static_dir, args.token)
