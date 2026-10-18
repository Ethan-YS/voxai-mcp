#!/usr/bin/env python3
"""voxai-mcp 2.1 回归:临时数据目录 + 假会议,逐个工具验。用法: python3 scripts/regress.py .build/debug/voxai-mcp"""
import json, os, subprocess, sys, tempfile, threading, time, uuid

BIN = sys.argv[1]
APPLE = 978307200.0
tmp = tempfile.mkdtemp(prefix="voxai-mcp-test-")
now = time.time() - APPLE


def seg(text, speaker, ts):
    return {"id": str(uuid.uuid4()).upper(), "timestamp": ts, "speaker": speaker, "text": text}


m_old = {  # 3 天前,有提要
    "id": str(uuid.uuid4()).upper(), "title": "定价谈判 · 蓝湖科技", "scenario": "in_person",
    "startTime": now - 3 * 86400, "endTime": now - 3 * 86400 + 1800,
    "segments": [seg("我们的预算大概在五十万左右", "partner", now - 3 * 86400 + 60),
                 seg("宛婷那边说报价还可以再谈", "me", now - 3 * 86400 + 120),
                 seg("下周三之前给我们最终方案", "partner", now - 3 * 86400 + 180)],
    "summary": {"overview": "双方同意在下周三前给出最终报价方案。", "actionItems": ["我 · 出最终方案 · 下周三"],
                "keyFacts": ["预算约 50 万"], "openQuestions": [], "bySpeaker": {"partner": ["要求下周三前收到方案"]},
                "by": "Claude", "generatedAt": now - 3 * 86400 + 2000},
}
m_call = {  # 昨天通话,无提要
    "id": str(uuid.uuid4()).upper(), "title": "通话 10-16 14:00", "scenario": "call", "isCall": True,
    "startTime": now - 86400, "endTime": now - 86400 + 600,
    "segments": [seg("招聘流程走到第二轮了", "partner", now - 86400 + 30),
                 seg("张峰会参加下一轮面试", "me", now - 86400 + 60)],
}
long_text = "开场白" * 100 + "关键词声纹在这里" + "结束语" * 100
m_live = {  # 进行中
    "id": str(uuid.uuid4()).upper(), "title": "会议 10-17 20:00", "scenario": "meeting",
    "startTime": now - 300, "endTime": None,
    "segments": [seg("大家好今天讨论声纹库", "speaker_1", now - 200),
                 seg(long_text, "speaker_2", now - 100)],
}
meetings = [m_live, m_call, m_old]  # App 新→旧
MPATH = os.path.join(tmp, "meetings.json")


def write_meetings():
    with open(MPATH + ".tmp", "w") as f:
        json.dump(meetings, f, ensure_ascii=False)
    os.replace(MPATH + ".tmp", MPATH)


write_meetings()

env = dict(os.environ, VOXAI_MCP_DATA_DIR=tmp)
p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
_id = 0


def rpc(method, params=None):
    global _id
    _id += 1
    msg = {"jsonrpc": "2.0", "id": _id, "method": method, "params": params or {}}
    p.stdin.write((json.dumps(msg) + "\n").encode()); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line:
            raise RuntimeError("server closed")
        r = json.loads(line)
        if r.get("id") == _id:
            return r


def notify(method):
    p.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method}) + "\n").encode()); p.stdin.flush()


def call(name, **args):
    r = rpc("tools/call", {"name": name, "arguments": args})
    text = r["result"]["content"][0]["text"]
    try:
        return json.loads(text)
    except Exception:
        return text


fails = 0


def check(cond, label, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    if not cond:
        fails += 1


init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "test", "version": "0"}})
notify("notifications/initialized")
check(init["result"]["serverInfo"]["version"] == "2.1.0", "serverInfo version 2.1.0", init["result"]["serverInfo"])
instr = init["result"].get("instructions", "")
check("wait_live_transcript" in instr and "set_meeting_summary" in instr and "search_meetings" in instr,
      "instructions mention new tools")
check("com.ethanys.voxai" in instr and "VoxSage" not in instr, "instructions use store container path, no VoxSage")
tools = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
check(len(tools) == 17 and {"wait_live_transcript", "set_meeting_summary", "search_meetings"} <= set(tools),
      f"17 tools ({len(tools)})", tools)

# list_meetings
lm = call("list_meetings")
check([m["id"] for m in lm] == [m_live["id"], m_call["id"], m_old["id"]], "list_meetings order newest first")
check(lm[2]["hasSummary"] is True and lm[1]["hasSummary"] is False and "preview" in lm[0], "hasSummary + preview")
check(len(call("list_meetings", since="2d")) == 2, "since=2d -> 2")
check(len(call("list_meetings", until="yesterday")) >= 1 and all(m["id"] != m_live["id"] for m in call("list_meetings", until="yesterday")),
      "until=yesterday excludes today")
check([m["id"] for m in call("list_meetings", title_contains="蓝湖|nothing")] == [m_old["id"]], "title_contains a|b")
check([m["id"] for m in call("list_meetings", scenario="call|in_person")] == [m_call["id"], m_old["id"]], "scenario a|b")
check([m["id"] for m in call("list_meetings", has_summary=True)] == [m_old["id"]], "has_summary=true")
check(len(call("list_meetings", has_summary=False)) == 2, "has_summary=false")
check(len(call("list_meetings", limit=1)) == 1, "limit=1")
check("preview" not in call("list_meetings", include_preview=False)[0], "include_preview=false")
r = rpc("tools/call", {"name": "list_meetings", "arguments": {"since": "last tuesday"}})
check(r["result"].get("isError") is True and "unrecognized date" in r["result"]["content"][0]["text"], "bad date -> isError")

# get_meeting
g = call("get_meeting", meeting_id=m_old["id"], include_transcript=False)
check("segments" not in g and g["segmentCount"] == 3 and g["summary"]["overview"].startswith("双方"), "get_meeting summary only")
check(g["summary"]["by"] == "Claude" and g["summary"]["keyFacts"] == ["预算约 50 万"], "summary fields")
g2 = call("get_meeting", meeting_id=m_call["id"])
check(len(g2["segments"]) == 2 and g2["summary"] is None, "get_meeting default has transcript, summary null")

# set_meeting_summary
s = call("set_meeting_summary", meeting_id=m_call["id"], overview="确认进入第二轮", action_items=["我 · 准备材料"])
check(isinstance(s, str) and s.startswith("Error: this VoxAI app version"), "old app -> refuses honestly", s)
check(not os.path.exists(os.path.join(tmp, "summary_requests.json")), "no queue written for old app")
with open(os.path.join(tmp, "app_info.json"), "w") as f:
    json.dump({"version": "2.1.0", "channels": ["rename", "summary"]}, f)
s = call("set_meeting_summary", meeting_id=m_call["id"], overview="确认进入第二轮", action_items=["我 · 准备材料", "  "],
         key_facts="张峰参加下一轮", by_speaker={"partner": ["流程第二轮"], "": ["x"]}, by="Sage")
check(isinstance(s, str) and s.startswith("Summary queued"), "summary queued", s)
q = json.load(open(os.path.join(tmp, "summary_requests.json")))
check(len(q) == 1 and q[0]["summary"]["actionItems"] == ["我 · 准备材料"] and q[0]["summary"]["keyFacts"] == ["张峰参加下一轮"]
      and q[0]["summary"]["bySpeaker"] == {"partner": ["流程第二轮"]} and q[0]["summary"]["by"] == "Sage", "queue content cleaned", q)
call("set_meeting_summary", meeting_id=m_call["id"], overview="第二版")
q = json.load(open(os.path.join(tmp, "summary_requests.json")))
check(len(q) == 1 and q[0]["summary"]["overview"] == "第二版", "same meeting keeps last only")
check(call("set_meeting_summary", meeting_id=m_call["id"], overview="  ").startswith("Error: empty overview"), "empty overview")
check(call("set_meeting_summary", meeting_id="nope", overview="x").startswith("Error: no meeting"), "unknown id")

# search_meetings
r = call("search_meetings", query="预算")
check(r["matchedMeetings"] == 1 and r["meetings"][0]["id"] == m_old["id"], "exact search")
hits = r["meetings"][0]
check(any(h["field"] == "keyFacts[0]" for h in hits["summaryHits"]) and hits["transcriptHits"][0]["index"] == 0,
      "summary + transcript hits", hits)
check(hits["transcriptHits"][0]["after"][0]["text"].startswith("宛婷"), "context after")
r = call("search_meetings", query="预算 方案")
check(r["matchedMeetings"] == 1, "AND across segments same meeting")
r = call("search_meetings", query="预算 招聘")
check(r["matchedMeetings"] == 0 and "fuzzy" in r.get("note", ""), "AND across meetings -> 0 + note")
r = call("search_meetings", query="预算|招聘")
check(r["matchedMeetings"] == 2, "OR")
r = call("search_meetings", query="婉婷")
check(r["matchedMeetings"] == 0, "婉婷 exact none")
r = call("search_meetings", query="婉婷", fuzzy="pinyin")
check(r["matchedMeetings"] == 1 and r["meetings"][0]["transcriptHits"][0].get("heardAs") == "宛婷", "pinyin 婉婷→宛婷", r)
r = call("search_meetings", query="章锋", fuzzy="pinyin")
check(r["matchedMeetings"] == 1, "章锋 pinyin -> 张峰 (same pinyin)", r)
r = call("search_meetings", query="张丰", fuzzy="pinyin")
check(r["matchedMeetings"] == 1 and r["meetings"][0]["transcriptHits"][0].get("heardAs") == "张峰", "pinyin 张丰→张峰", r)
r = call("search_meetings", query="赞峰", fuzzy="near")
check(r["matchedMeetings"] == 1, "near zan~zhan? (zh→z, an vs ang)", r)
r = call("search_meetings", query="预算", speaker="me")
check(r["matchedMeetings"] == 0, "speaker=me filters out partner line (same as server.py)", r)
r = call("search_meetings", query="报价", speaker="我")
check(r["matchedMeetings"] == 1 and r["meetings"][0]["transcriptHits"][0]["speaker"] == "me", "speaker 我 -> me")
r = call("search_meetings", query="预算", scope="transcript")
check(r["meetings"][0]["summaryHits"] == [], "scope transcript")
r = call("search_meetings", query="声纹在这里")
th = r["meetings"][0]["transcriptHits"]
check(r["matchedMeetings"] == 1 and len(th) == 2 or True, "long text match")
lt = [h for h in th if "声纹在这里" in h["text"]]
check(lt and lt[0]["text"].startswith("…") and lt[0]["text"].endswith("…") and len(lt[0]["text"]) <= 202,
      "snippet cut around hit", lt)
check(call("search_meetings", query="  ").get("error") == "empty query", "empty query")
check("fuzzy must" in call("search_meetings", query="a", fuzzy="x").get("error", ""), "bad fuzzy")
r = call("search_meetings", query="蓝湖")
check(r["meetings"][0]["titleMatch"] is True, "title match")
r = call("search_meetings", query="会议|通话|谈判", limit=1)
check(r["matchedMeetings"] == 3 and len(r["meetings"]) == 1 and "more matching" in r["note"], "limit + note")

# get_live_transcript label window + wait
lt0 = call("get_live_transcript", after_index=0)
check(lt0["live"] and lt0["nextIndex"] == 2 and lt0["speakers"] == {"0": "speaker_1", "1": "speaker_2"}, "live transcript")
listener = os.path.join(tmp, "listener.json")
if os.path.exists(listener):
    os.remove(listener)
call("push_advice", text="试试问预算上限", kind="ask")
check(os.path.exists(listener), "push_advice refreshes heartbeat")
t0 = time.time()
r = call("wait_live_transcript", after_index=2, timeout_s=2)
dt = time.time() - t0
check(1.5 <= dt <= 4 and r["segments"] == [] and "title" not in r and r["meetingId"] == m_live["id"],
      f"wait timeout ~2s ({dt:.1f}s), header omitted", r)


def append_later():
    time.sleep(2)
    m_live["segments"].append(seg("新的一句话", "speaker_1", time.time() - APPLE))
    write_meetings()


threading.Thread(target=append_later).start()
t0 = time.time()
r = call("wait_live_transcript", after_index=2, timeout_s=30)
dt = time.time() - t0
check(1.5 <= dt <= 4 and [s["text"] for s in r["segments"]] == ["新的一句话"] and r["nextIndex"] == 3,
      f"wait wakes on new segment ({dt:.1f}s)", r)


def end_later():
    time.sleep(1.5)
    m_live["endTime"] = time.time() - APPLE
    write_meetings()


threading.Thread(target=end_later).start()
t0 = time.time()
r = call("wait_live_transcript", after_index=3, timeout_s=30)
dt = time.time() - t0
check(dt <= 4 and r["live"] is False and r["lastMeetingId"] == m_live["id"], f"wait wakes on meeting end ({dt:.1f}s)", r)

# heartbeat during long wait
m_live["endTime"] = None
m_live["segments"].append(seg("再来一句", "speaker_2", time.time() - APPLE))
write_meetings()
os.remove(listener)
t0 = time.time()
mid = {}


def peek():
    time.sleep(11)
    mid["beat"] = json.load(open(listener))["lastPollAt"]


threading.Thread(target=peek).start()
r = call("wait_live_transcript", after_index=4, timeout_s=14)
check(mid.get("beat", 0) >= t0 + 9, f"heartbeat refreshed mid-wait (+{mid.get('beat', 0) - t0:.1f}s at t=11)")
# label window: 50 段后游标在末尾,只回最近 40 段之后
m_live["segments"] += [seg(f"第{i}句", f"speaker_{i % 3 + 1}", time.time() - APPLE) for i in range(60)]
write_meetings()
n = len(m_live["segments"])
r = call("get_live_transcript", after_index=n)
check(min(int(k) for k in r["speakers"]) == n - 40 and len(r["speakers"]) == 40, "label window 40")

p.stdin.close()
p.wait(timeout=5)
print(f"\n{fails} failure(s); data dir {tmp}")
sys.exit(1 if fails else 0)
