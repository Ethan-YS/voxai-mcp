#!/usr/bin/env python3
"""push_advice 推卡文件裁剪回归:超过上限时按会议开始时间留最近的场次。

旧规则按 key(会议 UUID)字典序删,删的是随机场次;直发版 10-23 查出 66 场推卡被删光。
本脚本让 key 的字典序和时间顺序故意反着来:旧规则会删掉最新的会议,新规则删最老的。
用法: python3 scripts/regress_advice_prune.py .build/debug/voxai-mcp
"""
import json, os, subprocess, sys, tempfile, time

BIN = sys.argv[1]
APPLE = 978307200.0
KEEP = 200
tmp = tempfile.mkdtemp(prefix="voxai-mcp-advice-")
now = time.time() - APPLE
DAY = 86400
MPATH = os.path.join(tmp, "meetings.json")
APATH = os.path.join(tmp, "live_advice.json")


def key(n):
    """UUID 形 key,n 越小字典序越靠前。"""
    return f"{n:08X}-0000-4000-8000-000000000000"


def card(text="卡"):
    return {"id": "c", "time": "10:00:00", "kind": "note", "text": text, "ref": ""}


def write(path, obj):
    with open(path + ".tmp", "w") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(path + ".tmp", path)


def advice():
    return json.load(open(APATH))["advice"]


# 已结束的会议:rank 0 最新、key 最小;rank 越大越老、key 越大(旧规则会先删最新的)
done = [{"id": key(r), "title": f"会议 {r}", "scenario": "meeting",
         "startTime": now - (r + 1) * DAY, "endTime": now - (r + 1) * DAY + 3600, "segments": []}
        for r in range(KEEP)]
live = {"id": key(0x7FFFFFFF), "title": "进行中", "scenario": "meeting", "startTime": now - 300, "endTime": None,
        "segments": [{"id": "s0", "timestamp": now - 60, "speaker": "me", "text": "开始"}]}
orphan = key(0xFFFFFFFF)          # 会议已从 meetings.json 删掉,字典序最后
write(MPATH, [live] + done)

p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=dict(os.environ, VOXAI_MCP_DATA_DIR=tmp))
_id = 0


def rpc(method, params=None):
    global _id
    _id += 1
    p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params or {}}) + "\n").encode())
    p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line:
            raise RuntimeError("server closed")
        r = json.loads(line)
        if r.get("id") == _id:
            return r


def call(name, **args):
    return rpc("tools/call", {"name": name, "arguments": args})["result"]["content"][0]["text"]


fails = 0


def check(cond, label, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    if not cond:
        fails += 1


rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}})
p.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n").encode()); p.stdin.flush()

# ① 没超上限:一场都不删
write(APATH, {"updatedAt": "x", "advice": {done[0]["id"]: [card()], done[-1]["id"]: [card()], orphan: [card()]}})
r = call("push_advice", text="先确认对方预算", kind="ask")
a = advice()
check(r == "Pushed (ask, #1)", "push ok", r)
check(len(a) == 4 and orphan in a, "under limit: nothing removed", sorted(a))

# ② 超上限:200 场已结束 + 1 场已删会议 + 当前场 = 202 场 → 留 200 场
write(APATH, {"updatedAt": "x", "advice": {**{m["id"]: [card(m["title"])] for m in done}, orphan: [card()]}})
r = call("push_advice", text="报价写进纪要", kind="action", label="待办")
a = advice()
check(r == "Pushed (action, #1)", "push ok over limit", r)
check(len(a) == KEEP, f"over limit: keeps {KEEP}", len(a))
check(live["id"] in a and a[live["id"]][-1]["text"] == "报价写进纪要" and a[live["id"]][-1]["label"] == "待办",
      "current meeting kept with new card")
check(orphan not in a, "deleted meeting dropped first")
check(done[-1]["id"] not in a, "oldest meeting dropped")
check(done[0]["id"] in a and done[1]["id"] in a, "newest meetings kept (old rule dropped these: smallest keys)")
check(done[-2]["id"] in a and a[done[-2]["id"]][0]["text"] == done[-2]["title"], "kept meetings untouched")

# ③ 同场再推:不多删,条数累加
r = call("push_advice", text="第二张", kind="note")
a = advice()
check(r == "Pushed (note, #2)" and len(a) == KEEP and len(a[live["id"]]) == 2, "second push appends, no extra pruning", r)

p.stdin.close()
p.wait(timeout=5)
print(f"\n{fails} failure(s); data dir {tmp}")
sys.exit(1 if fails else 0)
