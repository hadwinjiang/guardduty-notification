"""
本地模拟验证：
  1. 启动 Mock 企业微信 Webhook（仅监听 127.0.0.1，模拟官方返回码与 4096 字节限制、限流 45009）
  2. 用 EventBridge 规则同款逻辑过滤事件（severity >= MIN_SEVERITY）
  3. 调用 Lambda handler，校验推送内容
用法：python3 tests/run_simulation.py
"""
import glob
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

KEY = "test-key-0000"
MIN_SEVERITY = 4.0
received = []
inject_rate_limit = {"remaining": 0}


class MockWeCom(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _reply(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        q = parse_qs(urlparse(self.path).query)
        if urlparse(self.path).path != "/cgi-bin/webhook/send" or q.get("key") != [KEY]:
            return self._reply({"errcode": 93000, "errmsg": "invalid webhook url"})
        if inject_rate_limit["remaining"] > 0:
            inject_rate_limit["remaining"] -= 1
            return self._reply({"errcode": 45009, "errmsg": "api freq out of limit"})
        msg = json.loads(raw)
        t = msg.get("msgtype")
        if t == "markdown":
            if len(msg["markdown"]["content"].encode()) > 4096:
                return self._reply({"errcode": 40058, "errmsg": "markdown.content exceed max length 4096"})
        elif t == "text":
            if not msg["text"].get("content"):
                return self._reply({"errcode": 40008, "errmsg": "invalid message type"})
        else:
            return self._reply({"errcode": 40008, "errmsg": "invalid message type"})
        received.append(msg)
        self._reply({"errcode": 0, "errmsg": "ok"})


def eventbridge_match(evt):
    """与 template.yaml 中 EventPattern 等价的本地匹配。"""
    return (evt.get("source") == "aws.guardduty"
            and evt.get("detail-type") == "GuardDuty Finding"
            and float(evt["detail"].get("severity", 0)) >= MIN_SEVERITY)


def main():
    srv = HTTPServer(("127.0.0.1", 0), MockWeCom)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    os.environ["WEBHOOK_URL"] = f"http://127.0.0.1:{port}/cgi-bin/webhook/send?key={KEY}"
    os.environ["MENTION_MOBILES"] = "13800000000"
    import app
    app.time.sleep = lambda s: None  # 跳过退避等待

    results, failures = [], []

    def check(name, cond):
        (results if cond else failures).append(name)
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}")

    for path in sorted(glob.glob(os.path.join(ROOT, "tests/events/*.json"))):
        evt = json.load(open(path))
        name = os.path.basename(path)
        sev = evt["detail"]["severity"]
        print(f"\n== {name} (severity={sev})")
        before = len(received)
        if not eventbridge_match(evt):
            print("  EventBridge 规则过滤：不匹配，不触发 Lambda")
            check(f"{name}: 低于阈值被过滤", sev < MIN_SEVERITY)
            continue
        r = app.lambda_handler(evt, None)
        new = received[before:]
        check(f"{name}: handler 返回 sent", r["status"] == "sent")
        check(f"{name}: 收到 markdown", new and new[0]["msgtype"] == "markdown")
        md = new[0]["markdown"]["content"]
        check(f"{name}: ≤4096 字节 (实际 {len(md.encode())})", len(md.encode()) <= 4096)
        check(f"{name}: 含控制台链接", "[在控制台查看](https://" in md)
        region = evt["detail"]["region"]
        check(f"{name}: 控制台链接指向 {region}", f"https://{region}.console.aws.amazon.com/guardduty/home?region={region}" in md)
        expect = {
            "ec2_cryptomining_high.json": ["实例：i-0abc1234def567890", "实例名称：geely-prod-web-01", "域名：xmr.pool.minergate.com"],
            "iam_anomalous_medium.json": ["[样例]", "IAM 主体：ec2-app-role", "来源 IP：198.51.100.23 Netherlands"],
            "real_sample_bitcoin.json": ["[样例]", "实例：i-99999999", "行为：DNS_REQUEST"],
        }.get(name, [])
        for kw in expect:
            check(f"{name}: 解析出「{kw}」", kw in md)
        if sev >= 7:
            check(f"{name}: 高危补发 @ text", len(new) == 2 and new[1]["text"]["mentioned_mobile_list"] == ["13800000000"])
        else:
            check(f"{name}: 非高危不 @", len(new) == 1)
        print("  ---- 推送内容预览 ----")
        print("  " + md[:600].replace("\n", "\n  ") + ("..." if len(md) > 600 else ""))

    print("\n== 异常场景")
    evt = json.load(open(os.path.join(ROOT, "tests/events/iam_anomalous_medium.json")))
    inject_rate_limit["remaining"] = 2
    before = len(received)
    app.lambda_handler(evt, None)
    check("限流 45009 两次后重试成功", len(received) == before + 1)

    inject_rate_limit["remaining"] = 5
    try:
        app.lambda_handler(evt, None)
        check("持续限流时抛异常（触发 Lambda 重试/DLQ）", False)
    except RuntimeError:
        check("持续限流时抛异常（触发 Lambda 重试/DLQ）", True)
    inject_rate_limit["remaining"] = 0

    good_url = os.environ["WEBHOOK_URL"]
    os.environ["WEBHOOK_URL"] = f"http://127.0.0.1:{port}/cgi-bin/webhook/send?key=wrong"
    try:
        app.lambda_handler(evt, None)
        check("错误 key 抛异常", False)
    except RuntimeError as e:
        check("错误 key 抛异常 (93000)", "93000" in str(e))
    os.environ["WEBHOOK_URL"] = good_url

    check("非 GuardDuty 事件被忽略",
          app.lambda_handler({"detail-type": "EC2 Instance State-change Notification"}, None)["status"] == "ignored")

    srv.shutdown()
    print(f"\n结果：{len(results)} 通过，{len(failures)} 失败")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
