#!/bin/sh
# 把「复述台」前端同步成 Vercel 站点（产物就放仓库根），提交并 push；Vercel 端已连 GitHub，push 即自动部署。
#
# 用法：
#   sh 发布到vercel.sh           # 同步 + 提交 + push（push 完 Vercel 自动上线）
#   sh 发布到vercel.sh --local   # 只同步文件，不碰 git
#
# ────────────────────────────────────────────────────────────
# 为什么产物放在仓库根（2026-10-14 踩坑）
#
# 用户把 GitHub 仓库连到 Vercel 后，Vercel 拿「仓库根目录」当站点根；
# 而仓库根原本没有 index.html，于是整站 404（"This page doesn't exist"）。
# 所以这里直接把站点产物生成到仓库根 —— 不依赖任何 Vercel 面板设置，
# push 一次就出正确站点。
#
# ────────────────────────────────────────────────────────────
# 为什么需要 api/proxy.js（2026-10-14 逐条实测）
#
# 2) 前端不能直接跨域调云服务：
#    - 预检 OPTIONS 只放行 Origin: null 与 http://localhost|127.0.0.1:*；真实公网域名一律 403；
#    - 服务端在应用层还会再看一次 Origin：带 https://xxx.vercel.app → 403 access_denied
#      「the request origin is not allowed for this client」；
#    - 而**不带 Origin 头的请求是放行的**（服务端到服务端就是这种）。
#    浏览器发出的请求一定带 Origin，所以前端怎么改都过不去 —— 必须中间加一层服务端代理。
#
# 3) 解法：Vercel Function 做服务端代理。
#    vercel.json 把同源的 /.cloud/:path* 重写成 /api/proxy?p=:path*（实测原始查询串会保留），
#    函数在服务端再 fetch 云服务 —— 服务端 fetch 不带 Origin，于是放行。
#    副本前端的 endpoint 改成 location.origin，SDK 打自己的域名，浏览器根本不发跨域请求。
#    ⚠️ 不要用 api/cloud/[...path].js 这种通配文件名：实测部署后是 404（简单函数 api/proxy.js 正常）。
#    —— 复述台/index.html 保持原样不动，WorkBuddy 那份不受影响。
#
# 4) 目录分工：复述台/ 是 WorkBuddy 云服务的部署目录，**只能在里面放那两份前端**。
#    Vercel 要的 index.html / api/ / vercel.json 一律生成到仓库根，
#    靠 .vercelignore 把复述台/、data/ 等排除掉，不上传到 Vercel。
# ────────────────────────────────────────────────────────────
set -e

cd "$(dirname "$0")"
HOST=https://english-retell.app.workbuddy.host

# 只清生成物
rm -f index.html guest-seed.js vercel.json .vercelignore
rm -rf api fonts
mkdir -p api
cp 复述台/index.html 复述台/guest-seed.js ./
# 字体（2026-10-14 引入思源宋体三档 + Cinzel 900）：和页面同源放 fonts/，不走 CDN。
# fonts/ 不能进 .vercelignore，否则线上标题会静默回退成系统宋体。
cp -R 复述台/fonts ./

# ---------- 站点首页：endpoint 指到同源 ----------
python3 - "$PWD/index.html" <<'PY'
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
print('✓ 站点首页已生成（endpoint → location.origin）')
PY

# ---------- 服务端代理函数 ----------
cat > api/proxy.js <<'JS'
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
cat > vercel.json <<'JSON'
{
  "rewrites": [
    { "source": "/.cloud/:path*", "destination": "/api/proxy?p=:path*" }
  ],
  "functions": {
    "api/proxy.js": { "maxDuration": 60 }
  }
}
JSON

# ---------- 只让站点产物上线 ----------
# 部署根＝仓库根，仓库里的一切默认都会被公开，所以这里逐项排除。
cat > .vercelignore <<'IGN'
# 仓库里除站点产物以外的内容，都不上传到 Vercel
复述台
data
_归档
.vercel
*.md
复述归档.py
播报查规则.js
发布到vercel.sh
每日英文播报台_离线快照.html
IGN

echo "✓ 已生成站点产物到仓库根：index.html / guest-seed.js / api/proxy.js / vercel.json / .vercelignore / fonts/"

if [ "$1" = "--local" ]; then
  echo "（--local：未提交）"
  exit 0
fi

# ---------- 提交并 push，Vercel 端自动部署 ----------
git add -A
if git diff --cached --quiet; then
  echo "没有变化，不用发布"
  exit 0
fi
git commit -q -m "复述台 Vercel 站点：同步前端与代理函数（$(date '+%Y-%m-%d %H:%M')）"
git push origin main
echo "✓ 已 push，等 Vercel 自动部署（约 30 秒）：https://english-retell.vercel.app"
