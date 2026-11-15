#!/usr/bin/env python3
"""Save decrypted JM API responses for tool/make_fixtures.py.

Usage: tool/capture_jm.py https://<api domain> <captures>/jm
The current API domains are in the list the app downloads on start
(JmNetwork.domainUrls); the defaults in lib/base.dart go stale.
"""
import sys, time, hashlib, json, subprocess, base64, urllib.request
def fetch(url, out):
    t = int(time.time())
    token = hashlib.md5(f"{t}18comicAPPContent".encode()).hexdigest()
    hdr = {"Accept": "*/*", "Accept-Language": "zh-CN,zh;q=0.9", "Origin": "https://localhost",
        "Referer": "https://localhost/", "X-Requested-With": "com.example.app", "Authorization": "Bearer",
        "token": token, "tokenparam": f"{t},2.0.11",
        "user-agent": "Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/138.0.0.0 Mobile Safari/537.36"}
    cmd = ['curl', '-sS', '-m', '20', '--compressed', url]
    for k, v in hdr.items(): cmd += ['-H', f'{k}: {v}']
    r = subprocess.run(cmd, capture_output=True)
    body = r.stdout
    if not body.strip().startswith(b'{'):
        print(url, 'ERR', r.stderr.decode()[:120], body[:120]); return None
    j = json.loads(body)
    data = j.get('data')
    if not isinstance(data, str):
        print(url, 'unexpected', str(j)[:200]); return None
    key = hashlib.md5(f"{t}185Hcomic3PAPP7R".encode()).hexdigest().encode()
    raw = subprocess.run(['openssl', 'enc', '-d', '-aes-256-ecb', '-nopad', '-K', key.hex()], input=base64.b64decode(data), capture_output=True).stdout
    text = raw.decode('utf-8', 'replace')
    end = max(text.rfind('}'), text.rfind(']'))
    text = text[:end+1]
    parsed = json.loads(text)
    open(out, 'w', encoding='utf-8').write(json.dumps(parsed, ensure_ascii=False, indent=1))
    print(url, 'ok', len(text), type(parsed).__name__, list(parsed.keys())[:12] if isinstance(parsed, dict) else len(parsed))
    return parsed
base = sys.argv[1]; out = sys.argv[2]
home = fetch(f"{base}/promote?&page=0", f"{out}/promote.json")
if home:
    s = fetch(f"{base}/search?&search_query=touhou&o=mr", f"{out}/search.json")
    cid = s['content'][0]['id'] if s else None
    print('cid', cid)
    if cid:
        time.sleep(1)
        info = fetch(f"{base}/album?id={cid}", f"{out}/album.json")
        time.sleep(1)
        fetch(f"{base}/chapter?&id={cid}", f"{out}/chapter.json")
