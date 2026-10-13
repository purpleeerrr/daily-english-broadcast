#!/usr/bin/env node
/* 播报查规则 —— 把《播报写作规则.md》里能机器判的几条落成检查器。
 *
 * 用法：
 *   node 播报查规则.js 稿件.json
 *   node 播报查规则.js 稿件.json --all      # 连通过的一起列出来
 *
 * 稿件.json 的形态（云库 materials 表导出的数组，或 {script: "..."} 单篇）：
 *   [{"id":1,"en_title":"...","script":"..."}]
 * 只想查一段正文时，也可以直接喂纯文本：node 播报查规则.js 稿子.txt
 *
 * 机器能判的：黑名单词 / 对举句式 / 无主语归因 / em dash 密度 /
 *             连续三句等长 / 长句后缺短判断句 / 总结式收尾 / 词数区间。
 * 机器判不了的（要人念一遍）：口播顺不顺、术语解释是不是人话、
 *            每句能不能当场被追问着解释、结尾的判断是不是新的。
 */
'use strict';
const fs = require('fs');

const BLACK = ['delve', 'tapestry', 'realm', 'landscape', 'testament', 'pivotal', 'robust',
  'seamless', 'leverage', 'foster', 'harness', 'unlock', 'elevate', 'showcase', 'game-changer',
  'meticulous', 'furthermore', 'moreover', 'additionally', 'in conclusion',
  "it's important to note", 'utilize', 'facilitate', 'in order to', 'reside', 'individuals',
  'commence', 'stands as', 'serves as'];

const PARALLEL = [
  [/\bnot just\b/i, 'not just'],
  [/\bnot only\b/i, 'not only'],
  [/\brather than\b/i, 'rather than'],
  [/\bisn'?t (about|the)\b[^.]*[,—‑-]\s*it'?s\b/i, "isn't X, it's Y"],
  [/\bis not (about|the)\b[^.]*[,—‑-]\s*it is\b/i, 'is not X, it is Y'],
  [/\bno longer\b[^.]*[,.—‑-]\s*(it|that|this)('s| is)\b/i, 'no longer X, it is Y'],
  /* 「more than just」才是 AI 味的抬价写法。
     不能写成 /\bmore than (just )?\b/ —— 那个会把 "earns more than one that holds a million"
     这种正常比较级也判成硬伤。 */
  [/\bmore than (just|simply)\b/i, 'more than just'],
  [/—\s*not [^,]{2,40},/i, '— not A, B'],
];

const VAGUE = [
  [/\bexperts say\b/i, 'experts say'],
  [/\bindustry observers\b/i, 'industry observers'],
  [/\bstudies show\b/i, 'studies show'],
  [/\banalysts say\b/i, 'analysts say'],
  [/\bit is said\b/i, 'it is said'],
];

const SUMMARY_END = [/^in conclusion\b/i, /^in summary\b/i, /^overall\b/i, /^to sum up\b/i];

/* 以小写字母开头的专有名词。断句时先占位，否则 "…week. xAI has…" 会被当成一句话。 */
const LOWERCASE_PROPER = ['xAI', 'eBay', 'iPhone', 'iPad', 'iOS', 'macOS', 'npm', 'n8n'];

function words(s) { return s.trim().split(/\s+/).filter(Boolean); }

function sents(s) {
  let t = String(s).replace(/\s+/g, ' ');
  LOWERCASE_PROPER.forEach((w, i) => { t = t.split(w).join('\u0001' + i + '\u0001'); });
  return t.split(/(?<=[.!?])\s+(?=[A-Z"'(\u0001])/)
    .map(x => x.trim())
    .filter(Boolean)
    .map(x => x.replace(/\u0001(\d+)\u0001/g, (_, i) => LOWERCASE_PROPER[+i]));
}

function check(script) {
  const out = { fail: [], warn: [], stats: {} };
  const text = String(script || '');
  const paras = text.split(/\n{2,}/).map(p => p.trim()).filter(Boolean);
  const S = sents(text);
  out.stats.words = words(text).length;
  out.stats.paras = paras.length;
  out.stats.sents = S.length;

  BLACK.forEach(b => {
    const re = new RegExp('\\b' + b.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'i');
    if (re.test(text)) out.fail.push('黑名单词：' + b);
  });
  PARALLEL.forEach(([re, name]) => { if (re.test(text)) out.fail.push('对举句式：' + name); });
  VAGUE.forEach(([re, name]) => { if (re.test(text)) out.fail.push('无主语归因：' + name); });

  paras.forEach((p, i) => {
    const n = (p.match(/—/g) || []).length;
    if (n > 1) out.fail.push('第 ' + (i + 1) + ' 段有 ' + n + ' 个 em dash（上限 1）');
  });

  S.slice(-3).forEach(s => SUMMARY_END.forEach(re => {
    if (re.test(s)) out.fail.push('总结式收尾：' + s.slice(0, 40));
  }));

  const L = S.map(s => words(s).length);
  for (let i = 0; i + 2 < L.length; i++) {
    const a = L[i], b = L[i + 1], c = L[i + 2];
    if (Math.abs(a - b) <= 2 && Math.abs(b - c) <= 2 && Math.abs(a - c) <= 2 && a >= 8) {
      out.fail.push('连续三句长度相近（' + a + '/' + b + '/' + c + ' 词）：' + S[i].slice(0, 34));
    }
  }
  for (let i = 0; i + 1 < L.length; i++) {
    if (L[i] >= 22 && L[i + 1] > 14) {
      out.warn.push('长句（' + L[i] + ' 词）后面没跟短判断句（下一句 ' + L[i + 1] + ' 词）');
    }
  }
  if (out.stats.words < 140 || out.stats.words > 180) {
    out.warn.push('词数 ' + out.stats.words + '（目标 150–170）');
  }
  return out;
}

/* ---------------- CLI ---------------- */
function main() {
  const argv = process.argv.slice(2);
  const showAll = argv.indexOf('--all') >= 0;
  const file = argv.filter(a => a.indexOf('--') !== 0)[0];
  if (!file) {
    console.error('用法：node 播报查规则.js 稿件.json [--all]');
    process.exit(2);
  }
  const raw = fs.readFileSync(file, 'utf8');
  let items;
  try {
    const j = JSON.parse(raw);
    items = Array.isArray(j) ? j : [j];
  } catch (e) {
    items = [{ id: '-', en_title: file, script: raw }];   /* 纯文本 */
  }

  let fails = 0, warns = 0;
  items.forEach((m, idx) => {
    const r = check(m.script);
    const title = m.en_title || m.title || ('#' + (m.id != null ? m.id : idx + 1));
    const bad = r.fail.length > 0;
    if (!bad && !showAll && !r.warn.length) return;
    fails += r.fail.length; warns += r.warn.length;
    console.log((bad ? '✗ ' : '· ') + title
      + '  ｜ 词数 ' + r.stats.words + ' / 段 ' + r.stats.paras + ' / 句 ' + r.stats.sents);
    r.fail.forEach(x => console.log('    硬伤 ' + x));
    r.warn.forEach(x => console.log('    提醒 ' + x));
  });
  console.log('—— 共 ' + items.length + ' 篇，硬伤 ' + fails + ' 条，提醒 ' + warns + ' 条');
  process.exit(fails ? 1 : 0);
}

if (require.main === module) main();
module.exports = { check, sents, words };
