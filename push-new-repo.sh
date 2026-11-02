#!/bin/bash
# 把本地已提交的内容推送到一个新仓库（需要 token 具备建仓 + 写 Contents 权限）
#
#   GITHUB_TOKEN=xxx ./push-new-repo.sh <repo-name> [public|private]
#
# 例：
#   GITHUB_TOKEN=github_pat_xxx ./push-new-repo.sh nessus-docker public
set -eu

NAME="${1:-nessus-docker}"
VIS="${2:-public}"
TOK="${GITHUB_TOKEN:-$(tr -d '\r\n' < ../gitpush.txt 2>/dev/null || true)}"
[ -n "$TOK" ] || { echo "缺少 GITHUB_TOKEN"; exit 1; }

USER=$(curl -sS -H "Authorization: token $TOK" https://api.github.com/user | sed -n 's/.*"login": "\([^"]*\)".*/\1/p' | head -1)
[ -n "$USER" ] || { echo "token 无效"; exit 1; }
echo "账号: $USER  仓库: $NAME ($VIS)"

CODE=$(curl -sS -o /tmp/createrepo.json -w "%{http_code}" -X POST \
  -H "Authorization: token $TOK" -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/repos \
  -d "{\"name\":\"$NAME\",\"private\":$([ "$VIS" = private ] && echo true || echo false),\"description\":\"Nessus Docker 破解版（引擎可升级，致谢 Adam-Zhong/nessus）\",\"has_issues\":true,\"has_wiki\":false}")

case "$CODE" in
  201) echo "仓库已创建" ;;
  422) echo "仓库已存在，直接推送" ;;
  *)   echo "建仓失败 HTTP $CODE:"; cat /tmp/createrepo.json; exit 1 ;;
esac

git remote remove neworigin 2>/dev/null || true
git remote add neworigin "https://${USER}:${TOK}@github.com/${USER}/${NAME}.git"
git -c http.version=HTTP/1.1 push -u neworigin main
echo "完成: https://github.com/${USER}/${NAME}"
