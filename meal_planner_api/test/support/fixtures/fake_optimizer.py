"""Test-only stand-in for optimizador.py speaking the same port protocol.

The behaviour is selected by payload["fake_mode"]:
  solve  - first candidate of every day and slot
  error  - an infeasible error frame with causes
  code   - an error frame with the code in payload["fake_error"]
  hang   - never answers
  crash  - exits with status 3
  noisy  - prints a non-JSON line before the solution
"""

import json
import sys
import time


def send(message):
    print(json.dumps(message), flush=True)


def main():
    handshake = json.loads(sys.stdin.readline())
    if handshake.get("type") != "handshake":
        return
    send({"type": "ready", "version": "1.0"})

    for line in sys.stdin:
        message = json.loads(line)
        if message.get("type") != "solve":
            continue

        request_id = message["id"]
        payload = message["payload"]
        mode = payload.get("fake_mode", "solve")

        if mode == "hang":
            time.sleep(60)
        elif mode == "crash":
            sys.exit(3)
        elif mode == "code":
            send({"type": "error", "id": request_id, "error": payload["fake_error"]})
        elif mode == "error":
            send({"type": "error", "id": request_id, "error": "infeasible",
                  "details": {"causes": ["no_recipe_for_slot"]}})
        else:
            if mode == "noisy":
                print("solver warming up", flush=True)
            meals = [
                {"day": day, "slot": slot,
                 "recipe_id": payload["candidates_by_slot"][slot][0]["recipe_id"]}
                for day in payload["days"]
                for slot in payload["slots"]
            ]
            send({"type": "solution", "id": request_id, "result": {"meals": meals}})


if __name__ == "__main__":
    main()
