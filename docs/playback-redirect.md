# 📄 技术文档：Navidrome 播放源重定向（WebDAV / 115 直链）

> 基线：`navidrome/navidrome` v0.64.2-22-g95f67d2c
> 上游改动：5 个文件 +40 / -6；新增 2 个文件（`core/stream/source.go` 405 行、`core/stream/ps115.go` 152 行）
> 一键重放：仓库根目录 `navidrome-diy.sh`（896 行，幂等，可反复执行）

---

## 一、需求

1. 音乐文件实际存放在 115 网盘，通过 ps2115 暴露成 WebDAV；本地 `/mnt/disk1/影音/音乐strm` 里是较小/旧的一份副本。
2. **扫描、入库、封面、歌词、歌单仍然读本地路径**，数据库不需要重建，不影响任何已有数据。
3. 只在**播放取字节**这一步换成远端来源。
4. 远端来源要能切换：服务器转发，或者把 115 直链交给客户端。
5. 上游更新后能一键重新打补丁，不手工改代码。

---

## 二、总体架构

```
扫描/入库/封面/歌词/歌单 ──→ 本地路径（不变，DB 不动）
                                    │
播放请求 ──→ MediaStreamer.NewStream()
                                    │
                          resolveSource(ctx, mf)      ← 新增逻辑的唯一入口
                                    │
              ┌─────────────────────┴─────────────────────┐
              │ PathOverride 命中                          │ 未命中
              ↓                                            ↓
   base + mf.Path（本地目录或 webdav:// URL）        mf.AbsolutePath()
              │
              ↓  PS115Mode = relay / redirect 时继续解析
   WebDAV 文件 → 302 → ps2115 → 302 → 115 CDN 直链
              │
      ┌───────┴────────┐
      │ 解析成功        │ 解析失败
      ↓                ↓
  直链 URL          退回 WebDAV URL（照旧转发，只是慢一点）
      │
      ├─ relay    : OpenSource() 以 Range 请求读直链，服务器转发字节
      └─ redirect : Serve() 直接 302，客户端自己去 CDN 取
```

要点：

- **不读 ps2115 的索引库**。pickcode 是从 WebDAV 的 302 Location 里拿到的，只用 WebDAV/HTTP 接口，`ps2115.db` 一次都不打开。
- **失败即降级**：任何一步出错都退回 WebDAV URL，不会出现"播不了"。
- **转码不受影响**：低码率请求由服务器转码，远端源先落盘再喂 ffmpeg（见第五节）。

---

## 三、配置

```toml
EnablePathOverride = true

#   "relay"    = 解析 115 直链，服务器转发字节（默认，兼容性最好）
#   "redirect" = 解析 115 直链，302 把链接交给客户端
PS115Mode = "relay"

[PathOverride]
# 键 = 库的路径（MusicFolder 里配的那个），值 = 播放时用的目标
"/music" = "webdav://user:pass@192.168.32.236:15222/音乐"
```

- `PathOverride` 的值可以是**本地目录**（如 `/mnt/ssd/music`）或 **`webdav://` / `webdavs://` / `http(s)://`** 地址。
- `webdav://` 只是 `http://` 的别名（WebDAV 的 GET 就是普通 HTTP GET），所以 ffmpeg 也能直接读同一个 URL。
- 不写 `PS115Mode` 时按 `relay` 处理。
- 想完全不走直链解析，把 `PS115Mode` 设成 `relay` 以外任意值（例如 `off`）也会退回纯 WebDAV 转发 —— 解析失败同样自动退回。

### 两种模式怎么选

| | relay | redirect |
|---|---|---|
| 客户端看到 | 只有 Navidrome | 302 到 `*.115cdn.net` |
| 服务器带宽 | 占（下载 + 上传） | 只占解析，不占数据 |
| 兼容性 | 好，任何客户端都能播 | **取决于客户端是否跟随跨主机跳转** |
| 实测首字节 | 0.5 s（解析已缓存） | 4 ms 返回 302 |

### 客户端兼容性（实测）

| 客户端 | 是否跟随跨主机 302 | 依据 |
|---|---|---|
| LMP v1.12.0 | ✅ 能播 | 每首歌只请求一次 302，随后直接从 CDN 取流 |
| 浏览器 `<audio>` | ✅ 能播 | `readyState=4`、`duration=238.67`、无 error |
| EchoSpace 2.0.2 (iOS) | ✅ 能播（**必须 307**） | 128 次请求全部 307、`responseSize=0`，播放正常 —— 说明字节全部来自 CDN |
| Primuse 1.0 | ❌ 播一声就跳 | 同一首歌 2 秒内重试 12 次，全部 302，一次没取到字节 |

规律一：**302 响应带 HTML 体（`Content-Type: text/html`，297 字节）会被部分播放器直接当失败**。
EchoSpace 就是这种情况——它其实会跟跨主机跳转，但一个"像网页"的 302 它不跟。

关键不是状态码，而是**响应形状**。实测 302 和 307 都能播（最终只保留 302），只要满足：

- 空 body（`Content-Length: 0`，不是 `http.Redirect` 写的 297 字节 HTML）
- `Content-Type` 是音频类型（`audio/mp4`，不是 `text/html`）
- 带 `Accept-Ranges: bytes`

```
EchoSpace + 302 + 空body + audio/mp4 → 95 次请求全部 302、responseSize=0、播放正常
EchoSpace + 307 + 空body + audio/mp4 → 128 次请求全部 307、responseSize=0、播放正常
EchoSpace + 302 + 297字节HTML + text/html → 反复重试、跳曲
```

规律二：**302 的目标主机和请求主机不同时，另一部分播放器会直接当失败**（安全策略），然后原地重试原 URL。
这类客户端只能用 `relay`。若想让 redirect 主用、又保留这些客户端，可按客户端加例外（`c=` 参数即客户端名），
在 `ps115Mode()` 里判断 `request.ClientFrom(ctx)` 即可，约 20 行。

本机线上选择 `redirect`（LMP 可播，服务器不占带宽）；换用不跟跳转的客户端时改回 `relay` 即可，不用换镜像。

---

## 四、代码改动清单

### 新增文件

**`core/stream/source.go`（405 行）** —— 播放源解析与远端读取，上游不存在此文件，永远不会冲突。

| 内容 | 作用 |
|---|---|
| `resolveSource()` | `PathOverride` 命中判断 + 直链解析，返回最终播放地址 |
| `joinSource()` | 本地路径 / URL 拼接（`filepath.Join` 会把 `webdav://` 的 `//` 折叠掉，不能用） |
| `isRemoteSource()` / `RedactURL()` | 判断远端、日志脱敏 |
| `OpenSource()` | 本地走 `os.Open`，远端返回可 Seek 的 HTTP 资源 |
| `remoteFile` | 基于 Range 的 `ReadSeekCloser`：`Read` / `Seek` / `openAt` / `probe`，让 `http.ServeContent` 原样可用 |
| `transcodeSource()` / `spoolRemote()` | 远端源转码前先落盘（见第五节） |
| `unwrapURLError()` / `parseContentRangeTotal()` | 错误串剥离 URL（否则 Subsonic 的二次 `Sprintf` 会把 `%20` 变成 `%!A(MISSING)`）、解析 `Content-Range` 总长度 |

**`core/stream/ps115.go`（152 行）** —— 115 直链解析。

| 内容 | 作用 |
|---|---|
| `ps115Mode()` | 读 `PS115Mode`，只认 `redirect`，其余一律 `relay` |
| `ps115Resolve()` | 逐跳读 `Location`：WebDAV → ps2115 → CDN，**跨主机第一跳就停**，不向 CDN 取任何字节 |
| `ps115DirectURL()` | 带缓存的入口，缓存到签名过期前 5 分钟（读 URL 里的 `t=` 参数） |
| `ps115Expiry()` | 从签名 URL 推断有效期；取不到时用 10 分钟 |

### 修改的上游文件

**`core/stream/media_streamer.go`（+22 / -3）**

1. `filePath := mf.AbsolutePath()` → `filePath := resolveSource(ctx, mf)`：唯一的拦截点。
2. raw 分支 `os.Open(filePath)` → `OpenSource(ctx, filePath)`：本地/远端统一入口。
3. `Stream` 结构体加 `redirectURL string`。
4. raw 分支加：`redirect` 模式下设 `redirectURL` 并 `return`（`ReadCloser` 置 `http.NoBody`，避免上游 `defer stream.Close()` 空指针 —— 这个坑踩过一次，会 panic 整个请求）。
5. `Serve()` 开头：有 `redirectURL` 就 `Cache-Control: no-store` + `http.Redirect(302)`。
6. 转码调用改为 `transcodeSource(transcodingCtx, job.ms.transcoder, ...)`。

**`conf/configuration.go`（+9）**

```go
EnablePathOverride bool
PathOverride       map[string]string
PS115Mode          string
```

**`core/ffmpeg/ffmpeg.go`（+10）**

- `isRemotePath()` 判定 http(s)，`fileExists()` 放行远端源。
- 远端源转码前 `spoolRemote()` 落盘。

**`core/stream/decider.go`（+1 / -1）**：探测用 `ProbeAudioStream(ctx, resolveSource(ctx, mf))`。

**`core/archiver.go`（+1 / -2）**：zip 批量下载走 `stream.OpenSource()`。

---

## 五、两个必须知道的实现细节

### 1. 转码必须先把远端文件落盘

ffmpeg 直接读远端 URL 有三个坑：

- 115 CDN 对 ffmpeg 的请求返回 403（curl / Go 都正常）；
- 签名 URL 带 `us=52428800`，单链接 50 MB 上限，超了读到一半 403；
- m4a/mp4 的 `moov` 在文件尾部，无法随机 seek。

所以 `spoolRemote()` 先用自研 Go 客户端把整个文件拉到转码缓存目录，再让 ffmpeg 读本地文件。转码缓存命中后不再下载。

### 2. `Seek` 不能省

`http.ServeContent` 依赖 `io.ReadSeeker` 处理 Range 和拖动。远端源用 `remoteFile` 实现按 Range 的 `Seek`，否则客户端拖动进度条会拿到错误数据或整首重下。

---

## 六、验证方法与实测数据

### 三种来源一致性（本地 / 映射目录 / WebDAV）

```
PASS  local   size=13874101  sha256=f6464e5e26b6dd0dc110594c8406b55bebe4004a2a7e7bbc0a462580e4920587
PASS  mapped  size=27467057  sha256=6270e47112ac66455a7176ee220c34b3aa82822eea653dee3cd9f4ebfb19743d
PASS  webdav  size=22141270  sha256=bb016d5b8990a7c4ec7797b2732cc428f337940b09eb9cb6eab2dfe968954ca4
```

### Range / 拖动

```
206 Partial Content
Content-Range: bytes 5000000-5000999/22141270
```

### 模式对比（同一首歌，6 次 Range 模拟 seek）

```
relay    : 480, 464, 499, 467, 538, 549 ms      ← 解析一次后直接打 CDN
纯 WebDAV : 3547, 160, 502, 294, 523, 483 ms    ← 每个请求都要三跳
redirect : 302 返回 4~5 ms，之后由客户端直连 CDN
```

### 转码

```
format=mp3&maxBitRate=128 → 200 audio/mpeg, 2282852 B, 4.5 s（含落盘）
缓存命中                  → 0.3 s
```

### 115 CDN 的已知特性（排查用）

- 响应头 `Content-Disposition: attachment`，`Content-Type` 有时是 `application/octet-stream`；
- 签名 URL：`t=` 约 1 小时有效，`us=52428800` 单链接 50 MB 上限；
- UA 不绑定签名（EchoSpace / AppleCoreMedia / Go-http-client 实测都返回 206）。

---

## 七、上游更新后怎么重放

```bash
cd /root/navidrome
git pull                     # 或 git fetch && git checkout <tag>
./navidrome-diy.sh           # 自动打补丁 + gofmt + 编译自检
```

脚本特性：

- **幂等**：二次运行全部输出"已是…跳过"，产物与工作树逐字节一致（已用干净 clone 验证）。
- **锚点校验**：上游结构变了导致锚点找不到时，直接报错退出，不会打出半个补丁。
- **自动备份**：改动前把原文件备份为 `*.backup.YYYYmmddHHMMSS`。
- **内嵌源码**：`source.go` / `ps115.go` 全文写在脚本里，不依赖仓库里已有的文件。

构建与发布：

```bash
make docker-image IMAGE_PLATFORMS=linux/amd64 DOCKER_TAG=navidrome:test
cd /docker/navidrome && docker compose up -d --force-recreate
cd /root/navidrome && ./push-dockerhub.sh navidrome:test    # 推 chaslllll/navidrome:{latest,<version>}
```

`push-dockerhub.sh` 说明：直连 `registry-1.docker.io` 传大层会 `timeout awaiting response headers`，脚本走本机代理（默认 `127.0.0.1:7890`），并用只含 PAT 的 `/root/.docker/skopeo-auth.json`（`~/.docker/config.json` 里的 access-token/refresh-token 条目会让 skopeo 报 `incorrect username or password`）。

---

## 八、故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `probing source: context canceled` | 客户端中途断开，回退路径跟着被取消 | 正常噪声，不影响其它请求 |
| `Requested MediaFileID not found` | 客户端缓存了旧曲目 ID | 客户端重新同步资料库 |
| 播放几秒就停 | 115 单链接 50 MB 上限 / 签名过期 | 用 relay 模式（服务器统一处理），不要 redirect |
| 转码失败 `Server returned 403` | ffmpeg 直接读了 CDN | 确认走的是 `transcodeSource`（落盘） |
| 302 后客户端无反应 | 客户端不跟随跨主机跳转 | 改 `PS115Mode = "relay"` |
| 播放只响一声就跳下一首 | 客户端不认带 HTML 体的 302，或客户端拒绝跨主机跳转 | 确认响应是 `302` + `Content-Length: 0` + 音频 `Content-Type`；仍不行则该客户端只能用 relay |
| 客户端能播但服务端看不到 200 | 正常：redirect 模式下服务端只回 307，字节走 CDN | 看 `responseSize=0` 且播放正常即为直连成功 |
| 封面加载慢 / `Request throttle capacity exceeded` | 客户端快速翻页触发限流 | 调 `getCoverArt` 限流或忽略 |

> ⚠️ 验证模式时**必须用不跟随重定向的客户端**（`curl -o /dev/null -w '%{http_code}'` 默认不跟随）。
> Python `urllib` / 浏览器会自动跟随 302 并把 CDN 的内容拉回来，看起来"播放成功"，
> 实际服务端返回的是 302 —— 排查时先看服务端日志的 `httpStatus`，别看客户端的结果。

---

## 九、未做 / 已知限制

- 只改了**播放侧**。扫描仍要求本地存在文件（strm 或占位文件），不支持"纯远端库"。
- 只支持 Basic 认证的 WebDAV。
- 远端源不支持 `Stat` 的完整语义，文件大小依赖 `Content-Range`/`Content-Length`。
- `redirect` 模式依赖客户端行为，EchoSpace 实测不跟随跨主机跳转。
