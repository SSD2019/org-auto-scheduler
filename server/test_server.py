#!/usr/bin/env python3
"""
Automated test suite for Org Auto Scheduler HTTP Bridge Server and API
"""

import json
import subprocess
import time
import urllib.request
import urllib.parse
import sys

BASE_URL = "http://127.0.0.1:8989"

def run_tests():
    print("==================================================")
    print(" Running Org Auto Scheduler Server Test Suite")
    print(f" Target: {BASE_URL}")
    print("==================================================")
    
    passed = 0
    failed = 0

    def assert_test(name, condition, details=""):
        nonlocal passed, failed
        if condition:
            print(f"  ✓ {name}")
            passed += 1
        else:
            print(f"  ✗ {name} FAIL: {details}")
            failed += 1

    # 1. Test Static files
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/")
        assert_test("GET / (index.html)", req.status == 200 and b"Org Auto Scheduler" in req.read())
    except Exception as e:
        assert_test("GET /", False, str(e))

    try:
        req = urllib.request.urlopen(f"{BASE_URL}/css/app.css")
        assert_test("GET /css/app.css", req.status == 200 and b"--bg-app" in req.read())
    except Exception as e:
        assert_test("GET /css/app.css", False, str(e))

    try:
        req = urllib.request.urlopen(f"{BASE_URL}/js/app.js")
        assert_test("GET /js/app.js", req.status == 200 and b"Org Auto Scheduler" in req.read())
    except Exception as e:
        assert_test("GET /js/app.js", False, str(e))

    try:
        req = urllib.request.urlopen(f"{BASE_URL}/manifest.json")
        assert_test("GET /manifest.json", req.status == 200 and b"Org Auto Scheduler" in req.read())
    except Exception as e:
        assert_test("GET /manifest.json", False, str(e))

    # 2. Test API Status
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/api/status")
        data = json.loads(req.read().decode("utf-8"))
        assert_test("GET /api/status", data.get("status") == "ok" and data.get("agenda_files_count") > 0, str(data))
    except Exception as e:
        assert_test("GET /api/status", False, str(e))

    # 3. Test API Agenda
    sample_task_id = None
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/api/agenda")
        data = json.loads(req.read().decode("utf-8"))
        assert_test("GET /api/agenda", data.get("status") == "ok" and len(data.get("days", [])) > 0)
        days = data.get("days", [])
        if days and days[0].get("tasks"):
            sample_task_id = days[0]["tasks"][0].get("id")
            print(f"     Found sample agenda task ID: {sample_task_id}")
    except Exception as e:
        assert_test("GET /api/agenda", False, str(e))

    # 4. Test API Review State
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/api/review")
        data = json.loads(req.read().decode("utf-8"))
        assert_test("GET /api/review", data.get("status") == "ok" and "entries" in data)
        if not sample_task_id:
            for ent in data.get("entries", []):
                if ent.get("type") == "task":
                    sample_task_id = ent.get("id")
                    break
    except Exception as e:
        assert_test("GET /api/review", False, str(e))

    # 5. Test API Review Action (toggle)
    if sample_task_id:
        try:
            payload = json.dumps({"action": "toggle", "task_id": sample_task_id}).encode("utf-8")
            req = urllib.request.Request(f"{BASE_URL}/api/review/action", data=payload, headers={"Content-Type": "application/json"})
            resp = urllib.request.urlopen(req)
            data = json.loads(resp.read().decode("utf-8"))
            assert_test("POST /api/review/action (toggle)", data.get("status") == "ok")
            
            # Toggle back to preserve state
            req2 = urllib.request.Request(f"{BASE_URL}/api/review/action", data=payload, headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req2)
        except Exception as e:
            assert_test("POST /api/review/action (toggle)", False, str(e))

    # 6. Test API Task Details
    if sample_task_id:
        try:
            req = urllib.request.urlopen(f"{BASE_URL}/api/tasks/{sample_task_id}")
            data = json.loads(req.read().decode("utf-8"))
            assert_test(f"GET /api/tasks/{sample_task_id[:8]}...", data.get("status") == "ok" and data.get("heading"))
        except Exception as e:
            assert_test("GET /api/tasks/{id}", False, str(e))

    # 7. Test API Adherence
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/api/adherence")
        data = json.loads(req.read().decode("utf-8"))
        assert_test("GET /api/adherence", data.get("status") == "ok")
    except Exception as e:
        assert_test("GET /api/adherence", False, str(e))

    # 8. Test API Insights
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/api/insights")
        data = json.loads(req.read().decode("utf-8"))
        assert_test("GET /api/insights", data.get("status") == "ok")
    except Exception as e:
        assert_test("GET /api/insights", False, str(e))

    print("==================================================")
    print(f" Test Results: {passed} PASSED, {failed} FAILED")
    print("==================================================")
    return failed == 0

if __name__ == "__main__":
    success = run_tests()
    sys.exit(0 if success else 1)
