#!/usr/bin/env bash
# 把本地构建的镜像推到 Docker Hub（chaslllll/navidrome）。
# 直连 registry-1.docker.io 传大层会超时，所以走本机 mihomo 代理；凭证只用 PAT 那一条。
set -euo pipefail

SRC="${1:-navidrome:test}"
REPO="${2:-chaslllll/navidrome}"

PROXY="${PROXY:-http://127.0.0.1:7890}"
AUTH=/root/.docker/skopeo-auth.json

if [ ! -f "$AUTH" ]; then
  python3 - "$AUTH" <<'PY'
import base64, json, sys
cfg = json.load(open("/root/.docker/config.json"))
a = cfg["auths"]["https://index.docker.io/v1/"]["auth"]
json.dump({"auths": {"https://index.docker.io/v1/": {"auth": a}}}, open(sys.argv[1], "w"))
PY
fi

VERSION=$(docker run --rm --entrypoint /app/navidrome "$SRC" --version 2>/dev/null | head -1 | awk '{print $1}')
BASE="${VERSION%%-*}"
echo "源镜像 : $SRC ($VERSION)"
echo "目标   : $REPO:{latest,$BASE}"

docker tag "$SRC" "$REPO:latest"
docker tag "$SRC" "$REPO:$BASE"

export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY"
for tag in latest "$BASE"; do
  echo "--- push $REPO:$tag"
  skopeo copy --retry-times 5 --dest-authfile "$AUTH" \
    "docker-daemon:$REPO:$tag" "docker://$REPO:$tag" >/dev/null
done

echo "--- 校验"
for tag in latest "$BASE"; do
  printf '%s -> %s\n' "$tag" "$(skopeo inspect --authfile "$AUTH" --format '{{.Digest}}' "docker://$REPO:$tag")"
done
