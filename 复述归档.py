#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
复述归档.py —— 把一次复述判定的结果写回「每日英文播报学习库」。

配套文档：复述判定标准.md（四维打分、掌握度档位、判定与复习排期的联动规则）

用法
----
    # 先看会改什么，不写库
    python3 复述归档.py --input judge.json --dry-run

    # 真写
    python3 复述归档.py --input judge.json

    # 也可以从标准输入喂
    printf '%s' '{"match":"阿里千问","结构":2,"准确":2,"语言":1,"自主":2}' | python3 复述归档.py --stdin

输入 JSON 字段
-------------
    record_id   记录 id（可选，二选一）
    match       在「英文标题 / 中文标题」里做子串匹配（可选，二选一）
    结构 准确 语言 自主    四个维度的分，各 0–2
    掌握度       0–5，省略则按总分推
    判定         达标 / 部分达标 / 未达标，省略则按掌握度推
    要点         写进「复述记录」那一行的要点原文（可多行）
    时刻         形如 2026-10-13 22:45，省略则用当前时间

依赖
----
    调用资料库 skill 的 query / batch-update 脚本，复用其鉴权，不自己发请求。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

DB_ID = "vzGB2OwC0GqkLXWSjg7cuu"
DB_NAME = "每日英文播报学习库"

SKILL_DB = Path(
    "/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/"
    "resources/plugins/workbuddy-builtin/skills/library/database"
)
PY = "/Users/violet/.workbuddy/binaries/python/versions/3.13.12/bin/python3"

# 表里的选项 id（永久，改过一次就固定，不要重新生成）
ROUND_IDS = {
    "新学": "swz9ds9hnptx1ecr",
    "第1轮": "imsuvvwqpnv9sds0",
    "第2轮": "botfbvhyz73xr3ah",
    "第3轮": "m46hg6j4g0h7657y",
    "第4轮": "9po083n72ij26dt2",
    "第5轮": "wuv55zu4b52m52po",
    "已巩固": "gqaqv9qt1bvpkuvv",
}
ROUNDS = list(ROUND_IDS.keys())
INTERVALS = [1, 2, 4, 7, 15]

JUDGE_IDS = {
    "未判定": "iOrfG02dYEwy",
    "未达标": "QRcJJnMw1gcB",
    "部分达标": "gnals9a3QCML",
    "达标": "lgWVS2dSQ4iD",
}
STATUS_RECORDED_ID = "974ig6xnh47p9rzi"  # 练习状态 = 已录制

MASTERY_NAMES = {
    0: "未掌握",
    1: "有印象",
    2: "能复述要点",
    3: "能完整复述",
    4: "能换词重组",
    5: "能迁移",
}


# ---------------------------------------------------------------- 基础工具

def run_script(name: str, *args: str) -> dict:
    cmd = [PY, str(SKILL_DB / name), *args]
    out = subprocess.run(cmd, capture_output=True, text=True)
    raw = (out.stdout or "").strip()
    if not raw:
        raise SystemExit(f"{name} 没有输出。stderr:\n{out.stderr}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        raise SystemExit(f"{name} 输出不是 JSON：\n{raw[:600]}")
    if isinstance(data, dict) and data.get("error"):
        raise SystemExit(f"{name} 报错：{data['error']}")
    return data


def query_rows() -> list:
    data = run_script("query_database_record.py", "--database-id", DB_ID, "--page-size", "100")
    return data.get("results") or []


def update_record(record_id: str, properties: dict, dry: bool):
    if dry:
        return {"dry_run": True}
    payload = {"record_id": record_id, "properties": properties}
    return run_script(
        "batch_update_database_records.py",
        "--database-id", DB_ID,
        "--records", json.dumps([payload], ensure_ascii=False),
    )


# ---------------------------------------------------------------- 判定规则

def score_to_mastery(total: int) -> int:
    if total <= 1:
        return 0
    if total <= 3:
        return 1
    if total <= 5:
        return 2
    if total == 6:
        return 3
    if total == 7:
        return 4
    return 5


def mastery_to_judge(mastery: int) -> str:
    if mastery == 0:
        return "未达标"
    if mastery <= 2:
        return "部分达标"
    return "达标"


def next_schedule(round_name: str, mastery: int, today: datetime):
    """按判定结果算新的复习轮次与下次复习日期。返回 (轮次名, 下次复习 YYYY-MM-DD 或 None)"""
    idx = ROUNDS.index(round_name) if round_name in ROUNDS else 0
    if mastery >= 3:                                    # 达标：往前走一格
        nxt = idx + 1
        if nxt >= len(ROUNDS) - 1:                      # 走到第 5 轮之后
            return "已巩固", None
        return ROUNDS[nxt], (today + timedelta(days=INTERVALS[idx])).strftime("%Y-%m-%d")
    if mastery >= 1:                                    # 部分达标：原地，明天再来
        return round_name if round_name in ROUND_IDS else "新学", (today + timedelta(days=1)).strftime("%Y-%m-%d")
    return "新学", (today + timedelta(days=1)).strftime("%Y-%m-%d")  # 未达标：退回起点


# ---------------------------------------------------------------- 主流程

def pick_row(rows: list, spec: dict) -> dict:
    rid = (spec.get("record_id") or "").strip()
    if rid:
        for r in rows:
            if r.get("record_id") == rid:
                return r
        raise SystemExit(f"没找到 record_id = {rid} 的记录")
    key = (spec.get("match") or "").strip()
    if not key:
        raise SystemExit("必须给 record_id 或 match")
    hits = [r for r in rows
            if key in str(r.get("英文标题", "")) or key in str(r.get("中文标题", ""))]
    if not hits:
        titles = "\n".join(f"  · {r.get('中文标题')}" for r in rows)
        raise SystemExit(f"「{key}」没有匹配到记录。表里现有：\n{titles}")
    if len(hits) > 1:
        names = "\n".join(f"  · {r.get('中文标题')}  ({r.get('record_id')})" for r in hits)
        raise SystemExit(f"「{key}」匹配到 {len(hits)} 条，请指定 record_id：\n{names}")
    return hits[0]


def main() -> None:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--input", default="")
    ap.add_argument("--stdin", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    try:
        args, _ = ap.parse_known_args()
    except SystemExit:
        raise SystemExit("参数解析失败")

    if args.stdin:
        raw = sys.stdin.read()
    elif args.input:
        raw = Path(args.input).read_text(encoding="utf-8")
    else:
        raise SystemExit("用 --input <json> 或 --stdin")
    try:
        spec = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"输入不是合法 JSON：{exc}")

    dims = {k: int(spec.get(k, 0)) for k in ("结构", "准确", "语言", "自主")}
    for k, v in dims.items():
        if not 0 <= v <= 2:
            raise SystemExit(f"{k} 要在 0–2 之间，现在是 {v}")
    total = sum(dims.values())

    mastery = spec.get("掌握度")
    mastery = score_to_mastery(total) if mastery is None else int(mastery)
    judge = spec.get("判定") or mastery_to_judge(mastery)

    stamp = (spec.get("时刻") or "").strip()
    now = datetime.now()
    if stamp:
        try:
            now = datetime.strptime(stamp, "%Y-%m-%d %H:%M")
        except ValueError:
            raise SystemExit("时刻要写成 2026-10-13 22:45 这种")
    stamp = now.strftime("%Y-%m-%d %H:%M")

    rows = query_rows()
    row = pick_row(rows, spec)

    old_round = str(row.get("复习轮次") or "新学")
    new_round, next_date = next_schedule(old_round, mastery, now)

    line = " | ".join([
        stamp, old_round, f"{total} 分", judge,
        " ".join(f"{k}{v}" for k, v in dims.items()),
        (spec.get("要点") or "").replace("\n", " ").strip(),
    ])
    log = str(row.get("复述记录") or "").strip()
    new_log = (log + "\n" + line) if log else line

    props = {
        "掌握程度": {"number": mastery},
        "最近判定": {"select": JUDGE_IDS[judge]},
        "最近复述": {"date": now.strftime("%Y-%m-%dT%H:%M:00+08:00")},
        "复述记录": {"text": new_log},
        "练习状态": {"select": STATUS_RECORDED_ID},
        "复习轮次": {"select": ROUND_IDS[new_round]},
    }
    if next_date:
        props["下次复习"] = {"date": next_date + "T00:00:00Z"}

    print(f"素材：{row.get('中文标题')}")
    print(f"记录：{row.get('record_id')}")
    print(f"打分：结构 {dims['结构']} ｜ 准确 {dims['准确']} ｜ 语言 {dims['语言']} ｜ 自主 {dims['自主']} ｜ 总分 {total}")
    print(f"判定：{judge} ｜ 掌握度 {mastery}（{MASTERY_NAMES[mastery]}）")
    print(f"轮次：{old_round} → {new_round}")
    print(f"下次复习：{next_date or '已巩固，不再排期'}")
    print(f"记录行：{line}")

    if args.dry_run:
        print("\n[dry-run] 没有写库。去掉 --dry-run 才会真写。")
        return

    res = update_record(row["record_id"], props, dry=False)
    ok = res.get("updated") or res.get("records") or res.get("success")
    print(f"\n写回结果：{json.dumps(res, ensure_ascii=False)[:400]}")

    # 回读核验
    time.sleep(0.6)
    fresh = next((r for r in query_rows() if r.get("record_id") == row["record_id"]), None)
    if fresh:
        print("回读核验："
              f"掌握程度={fresh.get('掌握程度')} ｜ 最近判定={fresh.get('最近判定')} ｜ "
              f"最近复述={fresh.get('最近复述')} ｜ 复习轮次={fresh.get('复习轮次')} ｜ "
              f"下次复习={fresh.get('下次复习')} ｜ 练习状态={fresh.get('练习状态')}")
        return
    print("回读没读到这条记录，请手动核对。")


if __name__ == "__main__":
    main()
