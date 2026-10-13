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
