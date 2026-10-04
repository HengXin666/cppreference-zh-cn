#!/usr/bin/env bash
#
# 把上游 cppreference 中文 html-book 同步进本仓库。
#
# 上游: myfreeer/cppreference2mshelp 的非预发布 Release,
#       资产 html-book-<YYYYMMDD>.tar.xz (即 "中文版cppreference参考文档" 的 html 部分)。
#       包内 reference/zh、reference/common 与本仓库 zh/、common/ 一一对应 (路径同构)。
#
# 幂等: 用 .github/sync-state.json 里的 asset_digest 当版本身份。
#       身份未变 => 不下载、不替换, 只刷新 README 状态块。
#
# 保活: GitHub 会在公开仓库"60 天无仓库活动"时自动停用 scheduled workflow
#       (官方文档 Disabling and enabling a workflow:
#        "scheduled workflows are automatically disabled when no repository activity
#         has occurred in 60 days")。注意判据是仓库活动(提交之类), 不是"workflow 有没有跑",
#       所以"每周触发 + 上游没变就完全不提交"依然会被停用。
#       本脚本每次运行都刷新 README 状态块里的"最后检查"日期, 使每周至少有一次真实提交。
#
# 本地可直接运行 (依赖 gh/curl/tar/xz/rsync/sha256sum/python3);
# Actions 里复用同一份代码, 不另写一套。
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-myfreeer/cppreference2mshelp}"
STATE_FILE="${STATE_FILE:-.github/sync-state.json}"
README_FILE="${README_FILE:-README.md}"
UPSTREAM_SUB="${UPSTREAM_SUB:-reference}"
FORCE="${FORCE:-0}"

cd "$(git rev-parse --show-toplevel)"

log() { printf '[sync] %s\n' "$*"; }
emit() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi; }
# 注意: 不要在这里预置 changed=false。GITHUB_OUTPUT 里同名 key 写两次的行为
# 取决于 runner 实现, 这里只在确定结论时写一次, 未写即视为 false。

for bin in gh curl tar xz rsync sha256sum python3; do
    command -v "$bin" >/dev/null 2>&1 || { log "缺少依赖: $bin"; exit 1; }
done

# ---------------------------------------------------------------- 解析上游身份
# 按发布时间倒序遍历“非 draft / 非 prerelease”的 release, 取第一个带
# html-book-<8位日期>.tar.xz 资产的。这样即使上游某次只发布了 en 版,
# 也能自动落到最近一个真正含中文 html-book 的 release 上。
meta="$(gh api "repos/${UPSTREAM_REPO}/releases?per_page=100" --jq '
    [.[] | select(.draft == false and .prerelease == false)]
    | sort_by(.published_at) | reverse
    | map(. as $r
          | ($r.assets[]? | select(.name | test("^html-book-[0-9]{8}\\.tar\\.xz$")))
          | [$r.tag_name, $r.published_at, .name, (.size | tostring), (.digest // ""), .browser_download_url])
    | (.[0] // []) | @tsv
')" || { log "查询上游 release 失败"; exit 1; }

TAG=""; PUBLISHED=""; ASSET=""; SIZE=""; DIGEST=""; URL=""
IFS=$'\t' read -r TAG PUBLISHED ASSET SIZE DIGEST URL <<<"$meta" || true

if [ -z "$TAG" ] || [ -z "$ASSET" ] || [ -z "$URL" ]; then
    log "上游最近的正式 release 里没有 html-book-*.tar.xz 资产"
    exit 1
fi
# 没有 sha256 就不下: 宁可不更新, 也不把无法校验的大包塞进仓库。
case "$DIGEST" in
    sha256:*) WANT_DIGEST="${DIGEST#sha256:}" ;;
    *) log "上游资产 $ASSET 未提供 sha256 digest, 放弃本次同步"; exit 1 ;;
esac

emit tag "$TAG"
emit asset "$ASSET"
log "上游最新: $TAG / $ASSET (${SIZE} 字节, sha256=$WANT_DIGEST)"

# ---------------------------------------------------------------- 比对版本身份
prev_digest=""
if [ -f "$STATE_FILE" ]; then
    prev_digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("asset_digest",""))' \
        "$STATE_FILE" 2>/dev/null || true)"
fi

content_changed=0
if [ "$FORCE" = "1" ] || [ -z "$prev_digest" ] || [ "$prev_digest" != "sha256:$WANT_DIGEST" ]; then
    content_changed=1
    log "版本身份变化: ${prev_digest:-<无>} -> sha256:$WANT_DIGEST"
else
    log "版本身份未变 ($prev_digest), 跳过内容同步。"
fi

if [ "$content_changed" = "1" ]; then
    # ------------------------------------------------------------ 下载并校验
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    log "下载 $ASSET ..."
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors -o "$tmp/$ASSET" "$URL"
    printf '%s  %s\n' "$WANT_DIGEST" "$tmp/$ASSET" | sha256sum -c - >/dev/null
    log "sha256 校验通过"

    mkdir -p "$tmp/x"
    tar -xJf "$tmp/$ASSET" -C "$tmp/x"
    for d in zh common; do
        [ -d "$tmp/x/$UPSTREAM_SUB/$d" ] || { log "包内结构不符: 缺 $UPSTREAM_SUB/$d"; exit 1; }
    done

    # ------------------------------------------------------------ 落盘
    # --delete: 上游删掉的页面本仓库也删 (镜像要镜到底)
    # --chmod : 上游包权限是 777, 统一压成 644/755, 否则每次同步都刷出几万个 mode change
    CHMOD_SPEC='Du=rwx,Dgo=rx,Fu=rw,Fgo=r'
    for d in zh common; do
        log "同步 $UPSTREAM_SUB/$d/ -> $d/"
        rsync -a --delete --chmod="$CHMOD_SPEC" "$tmp/x/$UPSTREAM_SUB/$d/" "$d/"
    done

    # 上游构建缺陷: 少量链接被写成 ../zh.cppreference.com/... , 在 Pages 上会解析到
    # <站点>/zh.cppreference.com/... (不存在)。它们本该是绝对外链。
    # 注意: 其余约 2.7 万处是 (../)+zh.cppreference.com 形式, 那是正常站内互链, 不动。
    # 注意: 这里刻意让 grep 单独成命令 (不用管道), 避免 set -o pipefail 下
    # "无匹配 -> grep 退出 1" 被误当成脚本失败。
    if grep -rql -- 'href="\.\./zh\.cppreference\.com' zh; then
        broken_before="$(grep -rl -- 'href="\.\./zh\.cppreference\.com' zh | wc -l)"
        log "修正 $broken_before 个文件里的失效相对链接"
        grep -rlZ -- 'href="\.\./zh\.cppreference\.com' zh \
            | xargs -0 -r sed -i 's|href="\.\./zh\.cppreference\.com|href="https://zh.cppreference.com|g'
    fi
    if grep -rql -- 'href="\.\./zh\.cppreference\.com' zh; then
        log "仍有文件含失效链接, 修正未生效"
        exit 1
    fi

    # 站点 /zh/ 目录索引依赖 zh/index.html; 上游 2026.05 起不再产出该文件。
    # 它与 首页.html 的唯一差异是页脚 "Online version" 一行 (已实测可字节级复现):
    #   首页.html: href="https://zh.cppreference.com/w/<URL 编码的标题>"
    #   index.html: href="https://zh.cppreference.com/w/"
    # 故按该规则重建, 保证 /zh/ 入口不 404。
    if [ -f zh/首页.html ]; then
        log "按派生规则重建 zh/index.html (上游 2026.05 起不再产出它)"
        sed 's|href="https://zh\.cppreference\.com/w/[^"]*">Online version|href="https://zh.cppreference.com/w/">Online version|' \
            zh/首页.html >zh/index.html
    fi

    # ------------------------------------------------------------ 写回版本身份
    content_rev="$(sed -n 's/.*Offline version retrieved \([0-9-]* [0-9:]*\).*/\1/p' zh/首页.html | head -1)"

    UPSTREAM_REPO="$UPSTREAM_REPO" TAG="$TAG" PUBLISHED="$PUBLISHED" ASSET="$ASSET" \
        SIZE="$SIZE" WANT_DIGEST="$WANT_DIGEST" CONTENT_REV="$content_rev" \
        python3 - "$STATE_FILE" <<'PY'
import json, os, sys

path = sys.argv[1]
data = {
    "schema": 1,
    "upstream_repo": os.environ["UPSTREAM_REPO"],
    "release_tag": os.environ["TAG"],
    "published_at": os.environ["PUBLISHED"],
    "asset_name": os.environ["ASSET"],
    "asset_size": int(os.environ["SIZE"]),
    "asset_digest": "sha256:" + os.environ["WANT_DIGEST"],
    "content_revision": os.environ["CONTENT_REV"],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    log "版本身份已写入 $STATE_FILE (content_revision=${content_rev:-未知})"
fi

# ---------------------------------------------------------------- 刷新 README 状态块
# 无论上游是否变化都要刷新: 一是让人在 README 上直接看到同步到哪一版、上次检查是什么时候,
# 二是保活 (理由见文件头)。日期取到"天", 所以同一天重复触发不会追加多余提交。
STATE_FILE="$STATE_FILE" README_FILE="$README_FILE" \
    NOW_DATE="$(TZ=Asia/Shanghai date '+%Y-%m-%d')" python3 - <<'PY'
import json, os, pathlib, re

readme_path = pathlib.Path(os.environ["README_FILE"])
state_path = pathlib.Path(os.environ["STATE_FILE"])

try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
except Exception:
    state = {}

rev = (state.get("content_revision") or "").strip()
tag = (state.get("release_tag") or "").strip()
asset = (state.get("asset_name") or "").strip()
repo = state.get("upstream_repo") or "myfreeer/cppreference2mshelp"
checked = os.environ["NOW_DATE"]
rev_date = rev.split(" ")[0] if rev else ""

if tag:
    release = f"[`{tag}`](https://github.com/{repo}/releases/tag/{tag})"
else:
    release = "未知"
synced = rev or "未知"
if asset:
    synced = f"{synced} — 上游 `{asset}` (release {release})"

block = "\n".join([
    "<!-- sync-status:begin (由 .github/workflows/sync-upstream.yml 自动维护, 请勿手改) -->",
    "",
    "> [!IMPORTANT]",
    f"> - **最后同步**: {synced}",
    f"> - **最后检查上游**: {checked} (Asia/Shanghai)",
    "",
    "<!-- sync-status:end -->",
]) + "\n"

text = readme_path.read_text(encoding="utf-8") if readme_path.exists() else ""

# 已有状态块就原地替换; 否则插到"一级标题 + 紧随的简介"之后, 保持其它内容原样。
pattern = re.compile(r"<!-- sync-status:begin.*?<!-- sync-status:end -->\n?", re.S)
if pattern.search(text):
    new_text = pattern.sub(block, text, count=1)
else:
    m = re.search(r"^#\s+.*\n", text, re.M)
    if m:
        insert_at = m.end()
        # 吞掉紧随标题的简介行 (引用块) 与其后的空行, 让状态块落在简介之下。
        tail = re.compile(r"(?:[ \t]*\n|>[^\n]*\n)*").match(text, insert_at)
        if tail:
            insert_at = tail.end()
        new_text = text[:insert_at].rstrip("\n") + "\n\n" + block + "\n" + text[insert_at:]
    else:
        new_text = text.rstrip("\n") + "\n\n" + block

# README 里凡是指向"镜像内容版本"的日期都要跟着走, 否则标题说新版本、简介说旧版本, 自相矛盾。
if rev_date:
    new_text = re.sub(
        r"^(#\s+cppreference\s+中文离线镜像)\s*\(\d{4}-\d{2}-\d{2}\)",
        lambda m: f"{m.group(1)} ({rev_date})",
        new_text, count=1, flags=re.M,
    )
    rev_cn = "{0}年{1}月{2}日".format(*(int(p) for p in rev_date.split("-")))
    new_text = re.sub(
        r"基于 \d{4}年\d{1,2}月\d{1,2}日发布的 html-book 构建",
        f"基于 {rev_cn}发布的 html-book 构建",
        new_text, count=1,
    )
    # "为 ... 的 YYYYMMDD 中文镜像" 与 "获取到了 YYYYMMDD 中文镜像" 同样指镜像版本。
    new_text = re.sub(
        r"(为 https://cppreference\.com/ 的 )\d{8}( 中文镜像)",
        lambda m: f"{m.group(1)}{rev_date.replace('-', '')}{m.group(2)}",
        new_text, count=1,
    )
    new_text = re.sub(
        r"(获取到了 )\d{8}( 中文镜像)",
        lambda m: f"{m.group(1)}{rev_date.replace('-', '')}{m.group(2)}",
        new_text, count=1,
    )

if new_text != text:
    readme_path.write_text(new_text, encoding="utf-8")
    print(f"[sync] README 状态块已刷新 (最后检查 {checked})")
else:
    print("[sync] README 状态块无变化")
PY

# ---------------------------------------------------------------- 报告结果
# 只看镜像内容、身份文件与状态块, 不被工作区里无关的个人改动干扰。
if [ -z "$(git status --porcelain -- zh common "$STATE_FILE" "$README_FILE")" ]; then
    log "内容与状态块均无变化, 无需提交。"
    exit 0
fi

emit changed true
if [ "$content_changed" = "1" ]; then
    emit content_changed true
fi
log "同步完成, 待提交改动 $(git status --porcelain -- zh common "$STATE_FILE" "$README_FILE" | wc -l) 项"
