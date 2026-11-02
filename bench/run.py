#!/usr/bin/env python3
"""Run look-up cases against the model with the app's exact prompt; print timing and output.

Usage: python3 bench/run.py [case-name ...]
The key comes from the file the app uses (~/Library/Application Support/Aside/together-api-key).
"""
import json, pathlib, re, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = (ROOT / "Sources/Aside/Prompt.swift").read_text()
SYSTEM = re.search(r'PROMPT:SYSTEM:BEGIN\n\s*static let system = """\n(.*?)\n"""', SRC, re.S).group(1)
FOLLOW = re.search(r'PROMPT:FOLLOWUP:BEGIN\n\s*static let followUpRule = """\n(.*?)\n"""', SRC, re.S).group(1)
MODEL = "deepseek-ai/DeepSeek-V4.1-Flash"

CASES = json.loads((ROOT / "bench/cases.json").read_text())


def key():
    return (pathlib.Path.home() / "Library/Application Support/Aside/together-api-key").read_text().strip()


def message(c):
    marked = c["context"].replace(c["term"], f"⟦{c['term']}⟧", 1) if c.get("context") else ""
    s = f"Look up: {c['term']}\n"
    if marked:
        s += f"\nText around it:\n{marked}\n"
    s += f"\nApp: {c.get('app', 'Claude')}"
    if c.get("window"):
        s += f" — window: {c['window']}"
    s += "\nToday: " + time.strftime("%-d %B %Y")
    return s


def stream(messages, k):
    body = {"model": MODEL, "messages": messages, "stream": True, "temperature": 0.3, "max_tokens": 420,
            "reasoning": {"enabled": False}}
    req = urllib.request.Request("https://api.together.xyz/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {k}", "Content-Type": "application/json", "User-Agent": "Aside/0.1"})
    t0 = time.perf_counter(); first = None; out = ""
    with urllib.request.urlopen(req, timeout=30) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line.endswith("[DONE]"):
                continue
            d = json.loads(line[5:])
            if d.get("choices") and d["choices"][0]["delta"].get("content"):
                if first is None:
                    first = time.perf_counter() - t0
                out += d["choices"][0]["delta"]["content"]
    return out, first or 0, time.perf_counter() - t0


def main():
    k = key()
    names = sys.argv[1:]
    for c in CASES:
        if names and c["name"] not in names:
            continue
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": message(c)}]
        out, ttft, total = stream(msgs, k)
        print(f"\n=== {c['name']}  ttft {ttft*1000:.0f}ms  total {total*1000:.0f}ms")
        print(out)
        if c.get("followup"):
            msgs += [{"role": "assistant", "content": out},
                     {"role": "user", "content": f"{c['followup']}\n\n({FOLLOW})"}]
            out2, ttft2, total2 = stream(msgs, k)
            print(f"--- follow-up: {c['followup']}  ttft {ttft2*1000:.0f}ms  total {total2*1000:.0f}ms")
            print(out2)


if __name__ == "__main__":
    main()
