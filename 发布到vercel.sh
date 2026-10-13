#!/bin/sh
# 把「复述台」的前端同步到 _vercel_deploy/ 并发到 Vercel（展示 + 可直接登录那一份）。
#
# 部署前必须做完的三件事，都写在这里，别手工漏掉：
#
# 1) 目录隔离：`vercel link` 会在运行目录里生成 .env.local（内含 VERCEL_OIDC_TOKEN）。
#    复述台/ 是 WorkBuddy 云服务的部署目录，下次重新发布会把整个目录传上去，
#    凭据就成了公网可读的。所以 Vercel 的链接状态与凭据一律留在 _vercel_deploy/。
#    详见 .gitignore 顶部的说明。
#
# 2) 为什么前端不能直接跨域调云服务（2026-10-14 逐条实测）：
#    - 预检 OPTIONS 只放行 Origin: null 与 http://localhost|127.0.0.1:*；真实公网域名一律 403；
#    - 服务端在应用层还会再看一次 Origin：带 https://xxx.vercel.app → 403 access_denied
#      「the request origin is not allowed for this client」；
#    - 而**不带 Origin 头的请求是放行的**（服务端到服务端就是这种）。
#    浏览器发出的请求一定带 Origin，所以前端怎么改都过不去 —— 必须中间加一层服务端代理。
#
# 3) 解法：Vercel Function 做服务端代理。
#    vercel.json 把同源的 /.cloud/:path* 重写成 /api/proxy?p=:path*（实测原始查询串会保留），
#    函数在服务端再 fetch 云服务 —— 服务端 fetch 不带 Origin，于是放行。
#    前端副本的 endpoint 改成 location.origin，SDK 打到自己的域名，浏览器根本不发跨域请求。
#    ⚠️ 不要用 api/cloud/[...path].js 这种通配文件名：实测部署后是 404（简单函数 api/proxy.js 正常）。
#    —— 复述台/index.html 保持原样不动，WorkBuddy 那份不受影响。
#
# 用法：sh 发布到vercel.sh
set -e

cd "$(dirname "$0")"
HOST=https://english-retell.app.workbuddy.host
OUT=_vercel_deploy

# 只清生成的产物，保留 .vercel/（那是项目链接状态，删了就得重新 link）
rm -f "$OUT/index.html" "$OUT/guest-seed.js" "$OUT/vercel.json" "$OUT/.vercelignore"
rm -rf "$OUT/api"
mkdir -p "$OUT/api"
cp 复述台/index.html 复述台/guest-seed.js "$OUT/"
printf '.env*\n.vercel/\n' > "$OUT/.vercelignore"

# ---------- 副本前端：endpoint 指到同源 ----------
python3 - "$PWD/$OUT/index.html" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "endpoint: 'https://english-retell.app.workbuddy.host',"
new = ("endpoint: location.origin,"
       "   /* 云服务不认公网域名的来源，Vercel 上由 vercel.json 把 /.cloud/* "
       "重写到同源代理函数 api/proxy.js（服务端再转发，不带 Origin） */")
if old not in s:
    sys.exit('找不到 endpoint 那行，先看看 复述台/index.html 是不是改了')
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
print('已把 Vercel 副本的 endpoint 改成同源')
PY

# ---------- 服务端代理函数 ----------
cat > "$OUT/api/proxy.js" <<'JS'
/* WorkBuddy 云服务的服务端代理。
 *
 * 为什么必须在服务端转一手（2026-10-14 实测）：
 *   云服务对请求来源有两道校验 —— ① 预检 OPTIONS 只放行 Origin: null 与 localhost；
 *   ② 应用层还看请求的 Origin，真实公网域名直接 403 access_denied。
 *   但「不带 Origin」的请求是放行的；浏览器发出的请求必带 Origin，只有服务端 fetch 不带。
 *
 * 路由：vercel.json 把 /.cloud/:path* 重写成 /api/proxy?p=:path*（原查询串会保留）。
 *
 * 安全：只按 p 拼到云服务的 /.cloud/ 下，不把浏览器传来的 origin / referer / cookie 带过去。
 */
const HOST = 'https://english-retell.app.workbuddy.host';
const KEEP = ['x-wb-webapp-access-key', 'authorization', 'content-type', 'accept'];

module.exports = async (req, res) => {
  try {
    const p = String(req.query.p || '').replace(/^\/+/, '');
    if (!p) return res.status(400).json({ error: 'missing_path' });

    const qs = new URLSearchParams();
    Object.keys(req.query).forEach(k => {
      if (k === 'p' || k === 'path') return;      // 重写塞进来的，别转发
      const v = req.query[k];
      if (Array.isArray(v)) v.forEach(x => qs.append(k, x)); else qs.append(k, v);
    });
    const q = qs.toString();
    const url = HOST + '/.cloud/' + p + (q ? '?' + q : '');

    const headers = {};
    KEEP.forEach(k => { if (req.headers[k]) headers[k] = req.headers[k]; });

    const init = { method: req.method, headers, redirect: 'manual' };
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      if (chunks.length) init.body = Buffer.concat(chunks);
    }

    const r = await fetch(url, init);
    const buf = Buffer.from(await r.arrayBuffer());
    const ct = r.headers.get('content-type');
    if (ct) res.setHeader('content-type', ct);
    res.setHeader('cache-control', 'no-store');
    res.status(r.status).send(buf);
  } catch (e) {
    res.status(502).json({ error: 'proxy_failed', error_description: String((e && e.message) || e) });
  }
};
JS

# ---------- vercel.json ----------
cat > "$OUT/vercel.json" <<'JSON'
{
  "rewrites": [
    { "source": "/.cloud/:path*", "destination": "/api/proxy?p=:path*" }
  ],
  "functions": {
    "api/proxy.js": { "maxDuration": 60 }
  }
}
JSON

cd "$OUT"
# 要的是一个别人不用登录就能打开的地址 → 直接发生产环境
vercel deploy --prod --yes
