# navidrome-diy

给 [Navidrome](https://github.com/navidrome/navidrome) 打一层最小补丁，让**播放**从远端源取字节，
而**扫描 / 入库 / 封面 / 歌词 / 歌单仍然读本地库**。数据库不需要重建，已有数据不动。

适合这种场景：本地库是网盘（115、阿里云盘…）经 WebDAV 或 STRM 映射出来的，想做到

- 本地只放索引和小文件，播放时才去远端取原始音质
- raw 原始音质优先把网盘签名直链交给客户端，服务器不占音频带宽；拿不到直链时自动回落 WebDAV

## 播放策略（单一策略，无模式开关）

补丁只有一种行为：**服务器永远不主动请求 115 CDN 签名直链的字节**。115 要求签名直链的 UA 与
请求时一致，服务器自己的 UA 不匹配，取不到字节。

- **raw 原始音质播放**：先解析 115 签名直链（走源站的 302，只取 URL 不读 body）。
  - 解析成功 → 返回 `302`，`Location` 指向签名直链，由客户端用自己的 UA 去取字节；服务器只出一次 302，不占音频带宽。
  - 解析失败（拿不到直链）→ **自动回落 WebDAV**，由服务器从 WebDAV 读取字节并转发（Basic 认证，无 UA 耦合）。这是降级，不是播放失败：慢一点，但能播。
- **低码率转码请求**：仍由服务器取字节；远端源先 spool 落盘，再喂给 ffmpeg（签名直链不交给 ffmpeg）。
- **扫描 / 入库 / 封面 / 歌单**：仍读本地库路径，DB 不动。

配置只需：

```toml
EnablePathOverride = true

[PathOverride]
"/music" = "webdav://user:pass@192.168.1.10:15222/音乐"
```

`PathOverride` 的值可以是本地目录，也可以是 `webdav://` / `webdavs://` / `http(s)://`。
`PS115Mode` 配置项保留仅为兼容已有配置文件解析，**已不再生效，无需设置**（写任何值都不改变行为）。

### 客户端兼容性（实测）

302 这一路（直链解析成功时）各客户端表现：

| 客户端 | 跟随 302 | 依据 |
|---|---|---|
| 浏览器 `<audio>` / NavidromeUI | ✅ | `readyState=4`，时长正确 |
| LMP v1.12.0 | ✅ | 每首一次 302，随后直连 CDN |
| EchoSpace 2.0.2 (iOS) | ✅ | 95 次请求全 302、`responseSize=0`，播放正常 |
| Primuse 1.0 (iOS) | ❌ | 媒体会话的重定向委托直接 `return nil`，任何跳转都不跟 |

Primuse 不跟随跨主机跳转**不等于播不了**：客户端不跟随时会自动回落 WebDAV，由服务器读字节转发，
服务器占用带宽、首字节稍慢，但播放正常。

**关键在响应形状，不在状态码**：302 必须带空 body、音频 `Content-Type` 和 `Accept-Ranges: bytes`。
`http.Redirect` 默认写 ~300 字节 HTML body + `text/html`，部分播放器会把它当错误页面而不跟。
这个响应形状在代码里固定，不是配置项。

## 快速开始

```bash
git clone https://github.com/navidrome/navidrome.git
cd navidrome
git checkout v0.64.2          # 或任意版本
curl -O https://raw.githubusercontent.com/chas0000/navidrome-diy/main/navidrome-diy.sh
chmod +x navidrome-diy.sh
./navidrome-diy.sh            # 打补丁 + gofmt + 编译自检
```

脚本是**幂等**的：重复执行只会输出"已是…跳过"；改动前自动备份为 `*.backup.YYYYmmddHHMMSS`；
上游结构变化导致锚点找不到时直接报错退出，不会打出半个补丁。
已在干净的 HEAD `95f67d2c` 上重放验证：产出与主工作区一致，编译通过；上游更新后重跑即可。

构建镜像：

```bash
make docker-image IMAGE_PLATFORMS=linux/amd64 DOCKER_TAG=navidrome:test
```

## 补丁做了什么

上游改动 **5 个文件 +60 / -6**，新增 2 个文件（上游不存在，永不冲突）：

| 文件 | 改动 |
|---|---|
| `core/stream/source.go`（新增，约 399 行） | 路径解析、远端源的 `ReadSeekCloser`、转码前 spool 落盘 |
| `core/stream/ps115.go`（新增，约 154 行） | 解析 115 签名直链（走源站的 302，不读任何索引库） |
| `core/stream/media_streamer.go` | 拦截点：raw 先解析直链 → 302；失败 → WebDAV 回落；转码入口 |
| `core/ffmpeg/ffmpeg.go` | 允许 URL 输入，远端源先落盘 |
| `conf/configuration.go` | `EnablePathOverride` / `PathOverride`；`PS115Mode` 保留解析但不再生效 |
| `core/stream/decider.go` | 探测走 `resolveSource` |
| `core/archiver.go` | zip 批量下载走 `OpenSource` |

细节、验证数据、故障排查见 [docs/playback-redirect.md](docs/playback-redirect.md)。

## 预构建镜像（GitHub Actions）

仓库带一个 workflow，把补丁打到上游指定版本上、构建镜像并推到 **GitHub Container Registry**（不推 Docker Hub）。

```bash
docker pull ghcr.io/chas0000/navidrome-diy:latest
```

标签规则：

| 触发 | 标签 |
|---|---|
| push 到 `main` | `latest`、`sha-<短 sha>` |
| 打 tag `v1.0.0` | `v1.0.0`、`sha-<短 sha>` |
| 手动触发（可指定上游版本/平台） | `upstream-<ref>`、`sha-<短 sha>` |

手动构建别的上游版本或多平台：

```bash
gh workflow run build-image -f upstream_ref=v0.64.2 -f platforms=linux/amd64,linux/arm64
```

> GHCR 的包默认可能是 **private**，需要在 `Packages` → 包设置里把可见性改成 public，否则别人
> `docker pull` 会 403。本仓库的 `navidrome-diy` 包已设为 public，可以直接拉。

## 上游更新后

```bash
git pull          # 或切到新 tag
./navidrome-diy.sh
```

补丁全部集中在脚本里（两个新文件的全文内嵌在脚本中），所以更新上游只需要重跑一次。

## 已知限制

- 只改播放侧，扫描仍要求本地存在文件（真实文件或 strm 占位）
- WebDAV 只支持 Basic 认证
- 网盘签名链接常有单链接大小上限（如 115 的 50 MB）：走 302 这一路的超大单曲可能中途断开；直链解析不出来而回落 WebDAV，或走服务器端转码时，都由服务器读字节，不受该上限影响
- 签名链接约 1 小时过期；长时间暂停后继续播放会失败，重新播放即可

## 许可

Navidrome 是 GPLv3，本补丁是其衍生作品，同样以 **GPLv3** 发布，见 [LICENSE](LICENSE)。
