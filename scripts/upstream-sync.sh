#!/usr/bin/env bash
# ============================================================
# upstream-sync.sh — 上游仓库同步工具
#
# 功能：
#   1. 检测上游仓库 (upstream) 是否有新提交
#   2. 拉取更新并展示变更摘要
#   3. 尝试合并到当前分支
#   4. 运行 Docker 构建测试
#   5. 推送到 origin（你的 fork）
#
# 使用方式：
#   ./scripts/upstream-sync.sh              # 交互模式（每步确认）
#   ./scripts/upstream-sync.sh --auto       # 自动模式（无冲突时自动推送）
#   ./scripts/upstream-sync.sh --check      # 仅检查模式（只看有无更新）
#   ./scripts/upstream-sync.sh --dry-run    # 模拟模式（合并但不推送）
#
# 前置条件：
#   git remote add upstream https://github.com/waoowaooAI/waoowaoo.git
# ============================================================

set -euo pipefail

# ── 颜色定义 ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ── 配置 ──────────────────────────────────────────────────
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
ORIGIN_REMOTE="origin"
LOCAL_BRANCH="main"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="${PROJECT_DIR}/logs/upstream-sync.log"

# ── 参数解析 ──────────────────────────────────────────────
MODE="interactive"  # interactive | auto | check | dry-run
for arg in "$@"; do
  case "$arg" in
    --auto)     MODE="auto" ;;
    --check)    MODE="check" ;;
    --dry-run)  MODE="dry-run" ;;
    --help|-h)
      echo "用法: $0 [--auto|--check|--dry-run|--help]"
      echo ""
      echo "  --auto      无冲突时自动合并并推送"
      echo "  --check     仅检查上游是否有更新"
      echo "  --dry-run   合并但不推送（模拟模式）"
      echo "  --help      显示帮助"
      exit 0
      ;;
  esac
done

# ── 工具函数 ──────────────────────────────────────────────
log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()  { echo -e "${GREEN}✅ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠️  $1${NC}"; }
err() { echo -e "${RED}❌ $1${NC}"; }
info(){ echo -e "${CYAN}ℹ️  $1${NC}"; }

confirm() {
  if [[ "$MODE" == "auto" ]]; then return 0; fi
  if [[ "$MODE" == "check" || "$MODE" == "dry-run" ]]; then return 0; fi
  echo -en "${BOLD}$1 [y/N]: ${NC}"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

ensure_log_dir() {
  mkdir -p "$(dirname "$LOG_FILE")"
}

write_log() {
  ensure_log_dir
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ── 主流程 ────────────────────────────────────────────────

cd "$PROJECT_DIR"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  🔄 上游仓库同步工具 (upstream-sync)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  模式:     ${CYAN}${MODE}${NC}"
echo -e "  上游:     ${CYAN}${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}${NC}"
echo -e "  本地:     ${CYAN}${LOCAL_BRANCH}${NC}"
echo -e "  远程:     ${CYAN}${ORIGIN_REMOTE}/${LOCAL_BRANCH}${NC}"
echo ""

# ── Step 1: 检查前置条件 ────────────────────────────────
log "Step 1/6: 检查前置条件..."

if ! git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
  err "未找到 '${UPSTREAM_REMOTE}' 远程仓库"
  echo "请先运行: git remote add upstream https://github.com/waoowaooAI/waoowaoo.git"
  exit 1
fi

# 检查工作区是否干净
if [[ -n "$(git status --porcelain)" ]]; then
  warn "工作区有未提交的更改:"
  git status --short
  echo ""
  if ! confirm "是否先 stash 这些更改再继续?"; then
    err "请先提交或 stash 更改后再同步"
    exit 1
  fi
  if git stash push -m "upstream-sync: auto stash $(date '+%Y%m%d_%H%M%S')" 2>&1 | grep -q "No local changes"; then
    STASHED=false
  else
    ok "已 stash 工作区更改"
    STASHED=true
  fi
else
  STASHED=false
fi

ok "前置条件检查通过"

# ── Step 2: 拉取上游更新 ────────────────────────────────
log "Step 2/6: 拉取上游最新代码..."

git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>&1 | head -5
ok "已拉取上游 ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"

# ── Step 3: 检查差异 ────────────────────────────────────
log "Step 3/6: 检查差异..."

LOCAL_HEAD=$(git rev-parse HEAD)
UPSTREAM_HEAD=$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}")
MERGE_BASE=$(git merge-base HEAD "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo "")

if [[ "$LOCAL_HEAD" == "$UPSTREAM_HEAD" ]]; then
  ok "已经是最新，无需同步"
  write_log "CHECK: 无新提交 (HEAD=$LOCAL_HEAD)"
  
  # 恢复 stash
  if [[ "$STASHED" == "true" ]]; then
    git stash pop
    ok "已恢复 stash 的更改"
  fi
  exit 0
fi

# 统计差异
if [[ -n "$MERGE_BASE" ]]; then
  AHEAD=$(git rev-list --count HEAD "^${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo "0")
  BEHIND=$(git rev-list --count "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" "^HEAD" 2>/dev/null || echo "0")
else
  AHEAD="?"
  BEHIND="?"
fi

echo ""
echo -e "  ${BOLD}差异摘要:${NC}"
echo -e "  - 本地领先上游:   ${GREEN}${AHEAD}${NC} 个提交"
echo -e "  - 上游领先本地:   ${YELLOW}${BEHIND}${NC} 个提交"
echo ""

if [[ "$BEHIND" == "0" ]]; then
  ok "上游没有新提交（本地领先 ${AHEAD} 个提交）"
  write_log "CHECK: 上游无更新 (本地领先 ${AHEAD})"
  
  if [[ "$STASHED" == "true" ]]; then
    git stash pop
    ok "已恢复 stash 的更改"
  fi
  exit 0
fi

# 显示上游新增的提交
echo -e "  ${BOLD}上游新提交:${NC}"
git log --oneline --no-merges HEAD.."${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" | head -20
echo ""

# 显示变更文件统计
echo -e "  ${BOLD}变更文件统计:${NC}"
git diff --stat HEAD..."${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" | tail -5
echo ""

write_log "DIFF: 上游新增 ${BEHIND} 个提交"

# 检查模式
if [[ "$MODE" == "check" ]]; then
  info "检查模式：仅展示差异，不执行合并"
  
  if [[ "$STASHED" == "true" ]]; then
    git stash pop
    ok "已恢复 stash 的更改"
  fi
  exit 0
fi

# ── Step 4: 合并 ────────────────────────────────────────
log "Step 4/6: 合并上游更新..."

if [[ "$MODE" == "interactive" ]]; then
  if ! confirm "是否合并上游的 ${BEHIND} 个新提交?"; then
    warn "跳过合并"
    if [[ "$STASHED" == "true" ]]; then
      git stash pop
    fi
    exit 0
  fi
fi

# 尝试合并
MERGE_OUTPUT=$(git merge "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" --no-edit 2>&1) || {
  err "合并出现冲突！"
  echo ""
  echo -e "${RED}冲突文件:${NC}"
  git diff --name-only --diff-filter=U
  echo ""
  warn "请手动解决冲突后运行:"
  echo "  git add ."
  echo "  git commit"
  echo "  git push origin main"
  write_log "MERGE: 冲突 - 需要手动解决"
  
  if [[ "$MODE" == "auto" ]]; then
    # 自动模式下回滚合并
    git merge --abort
    err "自动模式：合并因冲突而回滚"
    
    if [[ "$STASHED" == "true" ]]; then
      git stash pop
    fi
    exit 1
  fi
  exit 1
}

echo "$MERGE_OUTPUT"
ok "合并成功"
write_log "MERGE: 成功合并 ${BEHIND} 个提交"

# ── Step 5: 构建测试 ────────────────────────────────────
log "Step 5/6: Docker 构建测试..."

if [[ "$MODE" == "dry-run" ]]; then
  info "模拟模式：跳过构建测试"
else
  if [[ "$MODE" == "interactive" ]]; then
    if ! confirm "是否执行 Docker 构建测试? (耗时约 3 分钟)"; then
      warn "跳过构建测试"
    else
      echo "  正在构建..."
      if docker compose build app 2>&1 | tail -3; then
        ok "Docker 构建成功"
        write_log "BUILD: 成功"
      else
        err "Docker 构建失败！"
        warn "请检查构建日志并决定是否继续推送"
        write_log "BUILD: 失败"
        if ! confirm "构建失败，是否仍然推送?"; then
          exit 1
        fi
      fi
    fi
  elif [[ "$MODE" == "auto" ]]; then
    echo "  正在构建..."
    if docker compose build app 2>&1 | tail -3; then
      ok "Docker 构建成功"
      write_log "BUILD: 成功"
    else
      err "Docker 构建失败，自动模式下终止推送"
      write_log "BUILD: 失败 - 终止推送"
      exit 1
    fi
  fi
fi

# ── Step 6: 推送 ────────────────────────────────────────
log "Step 6/6: 推送到 origin..."

if [[ "$MODE" == "dry-run" ]]; then
  info "模拟模式：跳过推送"
  warn "如需推送，请运行: git push origin main"
  write_log "PUSH: 跳过 (dry-run)"
else
  if [[ "$MODE" == "interactive" ]]; then
    if ! confirm "是否推送到 ${ORIGIN_REMOTE}/${LOCAL_BRANCH}?"; then
      warn "跳过推送。如需推送，请运行: git push origin main"
      exit 0
    fi
  fi

  git push "$ORIGIN_REMOTE" "$LOCAL_BRANCH" 2>&1
  ok "已推送到 ${ORIGIN_REMOTE}/${LOCAL_BRANCH}"
  write_log "PUSH: 成功"
fi

# ── 恢复 stash ──────────────────────────────────────────
if [[ "$STASHED" == "true" ]]; then
  git stash pop
  ok "已恢复 stash 的更改"
fi

# ── 完成 ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅ 同步完成！${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
write_log "DONE: 同步完成"
