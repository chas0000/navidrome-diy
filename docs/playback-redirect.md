# 📄 技术文档：Navidrome 播放源重定向（WebDAV / 115 直链）

> 基线：`navidrome/navidrome` v0.64.2-22-g95f67d2c
> 上游改动：小改 5 个文件；新增 2 个文件（`core/stream/source.go` 约 399 行、`core/stream/ps115.go` 约 154 行）
> 一键重放：[chas0000/navidrome-diy](https://github.com/chas0000/navidrome-diy) 的 `navidrome-diy.sh`（幂等，可反复执行，重放后已实测编译通过）
> **单一策略，不再有模式开关**：raw 播放优先把 115 直链交给客户端自己取字节；直链解析失败时服务器从 WebDAV 读字节回落。`PS115Mode` 仅为兼容旧配置而保留，不再生效。

---

## 一、需求

1. 音乐文件实际存放在 115 网盘，通过 ps2115 暴露成 WebDAV；本地 `/mnt/disk1/影音/音乐strm` 里是较小/旧的一份副本。
2. **扫描、入库、封面、歌词、歌单仍然读本地路径**，数据库不需要重建，不影响任何已有数据。
3. 只在**播放取字节**这一步换成远端来源。
4. **服务器永远不主动请求 115 CDN 直链字节**：签名直链要求 UA 与签发时一致，服务器 UA 不匹配会被拒。raw 播放时服务器只解析出直链并用 302 交给客户端，由客户端用自己的 UA 取字节；解析不到直链才由服务器从 WebDAV 读字节回落。低码率转码仍由服务器取字节，但来源是 WebDAV 而非 CDN 直链。
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
              ├── raw 分支（原始音质）
              │        │
              │  ps115DirectURL()
              │  WebDAV → ps2115 → CDN 的 302 链
              │  只读 Location，不下载任何字节
              │        │
              │  ┌─────┴──────┐
              │  │ 拿到直链    │ 拿不到直链
              │  ↓            ↓
              │  设 redirectURL   OpenSource(WebDAV URL)
              │  Serve() 返回 302  服务器从 WebDAV 读字节（回落）
              │  空 body + 音频类型
              │  + Accept-Ranges + Cache-Control: no-store
              │        │
              │        ↓
              │  客户端用自己的 UA 从 CDN 取字节
              │
              └── 低码率转码分支：transcodeSource()
                    远端源 spool 到 cache/transcoding/remote-*.src
                    → ffmpeg 读本地文件（服务器取字节，来源为 WebDAV）
```

要点：

- **服务器不碰 CDN 字节**：`ps115DirectURL()` 只沿 302 链读 `Location`，拿到签名直链就停，不向 CDN 发任何取字节请求；字节一律由客户端用自己的 UA 获取。
- **失败即降级**：直链解析任何一步出错都退回服务器从 WebDAV 读字节，不会出现"播不了"；代价是首字节变慢、服务器占带宽。注意回落只由**服务端解析失败**触发，客户端拒绝 302 不会触发回落（见第八、九节）。
- **转码不受影响**：低码率请求仍由服务器取字节，远端源先落盘再喂 ffmpeg（见第五节）。

---

## 三、配置

```toml
EnablePathOverride = true

[PathOverride]
# 键 = 库的路径（MusicFolder 里配的那个），值 = 播放时用的目标
"/music" = "webdav://user:pass@192.168.32.236:15222/音乐"
```

- `PathOverride` 的值可以是**本地目录**（如 `/mnt/ssd/music`）或 **`webdav://` / `webdavs://` / `http(s)://`** 地址。
- `webdav://` 只是 `http://` 的别名（WebDAV 的 GET 就是普通 HTTP GET），所以 ffmpeg 也能直接读同一个 URL。
- **不需要任何模式选择**：`PS115Mode` 保留在配置结构里只为兼容旧配置文件解析，代码不再读取，设任何值（包括 `off`）都不生效。直链解析失败会自动回落 WebDAV，无需额外开关。

### 302 响应形状（关键，实测）

决定兼容性的是**响应形状**，不是状态码。当前实现固定为 302 +：

- 空 body（`Content-Length: 0`，不是 `http.Redirect` 写的 297 字节 HTML）；
- `Content-Type` 是音频类型（如 `audio/mp4`，不是 `text/html`）；
- `Accept-Ranges: bytes`；
- `Cache-Control: no-store`。

```
EchoSpace + 302 + 空body + audio/mp4 → 95 次请求全部 302、responseSize=0、播放正常
EchoSpace + 307 + 空body + audio/mp4 → 128 次请求全部 307、responseSize=0、播放正常
EchoSpace + 302 + 297字节HTML + text/html → 反复重试、跳曲
```

状态码不需要可配置：302 / 307 在空 body + 音频类型下都能播，最终固定用 302。

### 客户端兼容性（实测）

| 客户端 | 是否跟随跨主机 302 | 依据 |
|---|---|---|
| LMP v1.12.0 | ✅ 能播 | 每首歌只请求一次 302，随后直接从 CDN 取流 |
| 浏览器 `<audio>` | ✅ 能播 | `readyState=4`、`duration=238.67`、无 error |
| EchoSpace 2.0.2 (iOS) | ✅ 能播 | 302/307 在空 body 下都能播，请求全部 `responseSize=0`，字节来自 CDN |
| Primuse 1.0 | ❌ 播一声就跳 | 同一首歌 2 秒内重试 12 次，全部 302，一次没取到字节 |

规律一：**302 响应带 HTML 体（`Content-Type: text/html`，297 字节）会被部分播放器直接当失败**。EchoSpace 就是这种情况——它其实会跟跨主机跳转，但一个"像网页"的 302 它不跟。这已通过固定空 body + 音频类型解决。

规律二：**302 的目标主机和请求主机不同时，另一部分播放器会按安全策略直接拒绝并原地重试原 URL**（Primuse 1.0 实测）。当前策略里没有服务端开关可切：直链解析成功就回 302，只有解析失败才回落 WebDAV；客户端拒绝 302 **不会**触发回落。这类客户端的限制见第九节。

直连成功时服务端只回 302、不传音频字节；回落时服务端从 WebDAV 读取，首字节与带宽都会受影响。

---

## 四、代码改动清单

### 新增文件

**`core/stream/source.go`（约 399 行）** —— 播放源解析与远端读取，上游不存在此文件，永远不会冲突。

| 内容 | 作用 |
|---|---|
| `resolveSource()` | `PathOverride` 命中判断，返回**本地路径或 WebDAV URL**；不再在此处解析直链（直链由 raw 分支单独取） |
| `joinSource()` | 本地路径 / URL 拼接（`filepath.Join` 会把 `webdav://` 的 `//` 折叠掉，不能用） |
| `isRemoteSource()` / `RedactURL()` | 判断远端、日志脱敏 |
| `OpenSource()` | 本地走 `os.Open`，远端返回可 Seek 的 HTTP 资源 |
| `remoteFile` | 基于 Range 的 `ReadSeekCloser`：`Read` / `Seek` / `openAt` / `probe`，让 `http.ServeContent` 原样可用 |
| `transcodeSource()` / `spoolRemote()` | 转码前把远端源 spool 到 `cache/transcoding/remote-*.src`（见第五节） |
| `unwrapURLError()` / `parseContentRangeTotal()` | 错误串剥离 URL（否则 Subsonic 的二次 `Sprintf` 会把 `%20` 变成 `%!A(MISSING)`）、解析 `Content-Range` 总长度 |

**`core/stream/ps115.go`（约 154 行）** —— 115 直链解析，只有一套策略，没有模式分支。

| 内容 | 作用 |
|---|---|
| `ps115DirectURL()` | raw 分支调用；沿 WebDAV → ps2115 → CDN 的 302 链逐跳只读 `Location`，**跨主机第一跳就停，不下载任何字节**；带缓存，到签名过期前 5 分钟 |
| `ps115Expiry()` | 从签名 URL 推断有效期；取不到时用 10 分钟 |

> 旧版的 `ps115Mode()` 模式分支已移除；配置里的 `PS115Mode` 只作解析兼容，代码不再读取。

### 修改的上游文件

**`core/stream/media_streamer.go`（小改）**

1. `filePath := mf.AbsolutePath()` → `filePath := resolveSource(ctx, mf)`：唯一的拦截点。
2. raw 分支先调 `ps115DirectURL()`：成功则设置 `redirectURL` 并 `return`（`ReadCloser` 置 `http.NoBody`，避免上游 `defer stream.Close()` 空指针 —— 这个坑踩过一次，会 panic 整个请求）；失败则 `OpenSource(ctx, filePath)`，由服务器从 WebDAV 读字节回落。
3. `Stream` 结构体加 `redirectURL string`。
4. `Serve()` 开头：有 `redirectURL` 就返回 302 响应 —— 空 body + 音频 `Content-Type` + `Accept-Ranges: bytes` + `Cache-Control: no-store`。
5. 转码入口改为 `transcodeSource(transcodingCtx, job.ms.transcoder, ...)`。

**`conf/configuration.go`（小改）**

```go
EnablePathOverride bool
PathOverride       map[string]string
PS115Mode          string   // 仅兼容保留，代码不再读取
```

**`core/ffmpeg/ffmpeg.go`（小改）**

- `isRemotePath()` 判定 http(s)，`fileExists()` 放行远端源。
- 远端源转码前 `spoolRemote()` 落盘；不把 CDN 签名直链交给 ffmpeg。

**`core/stream/decider.go`（小改）**：探测用 `ProbeAudioStream(ctx, resolveSource(ctx, mf))`。

**`core/archiver.go`（小改）**：zip 批量下载走 `stream.OpenSource()`。

---

## 五、两个必须知道的实现细节

### 1. 转码必须先把远端源落盘

低码率转码仍由服务器取字节，但来源只选 **WebDAV**（不是 CDN 直链）。几个坑：

- 服务器**绝不能**把签名直链交给 ffmpeg：UA 与签发时不匹配会被 CDN 403；
- m4a/mp4 的 `moov` 在文件尾部，HTTP 随机 seek 不可靠；
- 签名 URL 带 `us=52428800`，单链接 50 MB 上限，超了读到一半 403 —— 这条现在由 302 直连路径交给客户端承担，转码路径用落盘规避。

所以 `transcodeSource()` 先用自研 Go 客户端把远端源拉到 `cache/transcoding/remote-*.src`，再让 ffmpeg 读本地文件。转码缓存命中后不再下载。

### 2. `Seek` 不能省

`http.ServeContent` 依赖 `io.ReadSeeker` 处理 Range 和拖动。WebDAV 回落路径用 `remoteFile` 实现按 Range 的 `Seek`，否则客户端拖动进度条会拿到错误数据或整首重下。

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

### 302 直连 vs WebDAV 回落（同一首歌，6 次 Range 模拟 seek）

```
302 直连    : 302 返回 4~5 ms，之后由客户端直连 CDN，服务端不传字节
WebDAV 回落 : 3547, 160, 502, 294, 523, 483 ms   ← 服务器从 WebDAV 读，首字节最慢约 3.5 s
```

### 转码

```
format=mp3&maxBitRate=128 → 200 audio/mpeg, 2282852 B, 4.5 s（含落盘到 remote-*.src）
缓存命中                  → 0.3 s
```

### 115 CDN 的已知特性（排查用）

- 响应头 `Content-Disposition: attachment`，`Content-Type` 有时是 `application/octet-stream`；
- 签名 URL：`t=` 约 1 小时有效，`us=52428800` 单链接 50 MB 上限；`ps115DirectURL()` 缓存到过期前 5 分钟；
- 签名直链绑定签发时的 UA：客户端用自己的 UA 取字节正常（EchoSpace / AppleCoreMedia 实测 206），**服务器 UA 不匹配会被拒** —— 这就是服务器只回 302、绝不自己取直链字节的原因。

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
- 按新策略重放后已实测编译通过。

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
| 日志 `Redirecting client to 115 direct link` | `ps115DirectURL()` 解析成功，已把直链以 302 交给客户端 | 正常；客户端应自行取字节，服务端 `responseSize=0` |
| 日志 `ps115 direct link unavailable, using WebDAV` | 直链解析失败（WebDAV/ps2115 不可达、路径映射不对、签名解析失败等），已回落服务器从 WebDAV 读字节 | 能播但首字节变慢、服务器占带宽；检查 WebDAV 服务、ps2115 与 `PathOverride` 映射 |
| 播放几秒就停 | 直连路径命中 115 单链接 50 MB 上限 / 签名过期 | 直连路径的已知限制；服务器只负责在过期前刷新直链，不能替客户端取字节 |
| 转码失败 `Server returned 403` | 把 CDN 直链当成了转码源 | 确认走 `transcodeSource`（远端源 spool 到 `remote-*.src`）；服务器永不取直链字节 |
| 302 后客户端无反应 | 客户端拒绝跨主机跳转，或响应形状不对 | 先看日志确认 302 已发出；检查空 body + 音频 `Content-Type` + `Accept-Ranges: bytes`。没有服务端模式开关可切，见第九节 |
| 播放只响一声就跳下一首 | 客户端不认带 HTML 体的 302，或拒绝跨主机跳转 | 确认响应是 `302` + `Content-Length: 0` + 音频 `Content-Type`；仍不行属客户端限制 |
| 客户端能播但服务端看不到 200 | 正常：服务端只回 302，音频字节由客户端直连 CDN，`responseSize=0` | `responseSize=0` 且播放正常即为直连成功 |
| 封面加载慢 / `Request throttle capacity exceeded` | 客户端快速翻页触发限流 | 调 `getCoverArt` 限流或忽略 |

> ⚠️ 验证时**必须用不跟随重定向的客户端**（`curl -o /dev/null -w '%{http_code}'` 默认不跟随）。
> Python `urllib` / 浏览器会自动跟随 302 并把 CDN 的内容拉回来，看起来"播放成功"，实际服务端返回的是 302。
> 先看服务端日志：`Redirecting client to 115 direct link` 表示 302 直连，`ps115 direct link unavailable, using WebDAV` 表示回落，别只看客户端结果。

---

## 九、未做 / 已知限制

- 只改了**播放侧**。扫描仍要求本地存在文件（strm 或占位文件），不支持"纯远端库"。
- 只支持 Basic 认证的 WebDAV。
- 远端源不支持 `Stat` 的完整语义，文件大小依赖 `Content-Range`/`Content-Length`。
- 服务器永不请求 CDN 直链字节：转码与回落都从 WebDAV 取字节；只有 raw 直连路径把 302 交给客户端。
- 302 直连依赖客户端跟随跨主机跳转（Primuse 1.0 实测不跟随）。直链解析失败才会回落 WebDAV，客户端拒绝 302 不会触发回落，这类客户端无法走直连路径。
- `PS115Mode` 只为兼容旧配置解析而保留，不再生效，无需设置。
