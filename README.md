# navidrome-diy

给 [Navidrome](https://github.com/navidrome/navidrome) 打一层最小补丁，让**播放**从远端源取字节，
而**扫描 / 入库 / 封面 / 歌词 / 歌单仍然读本地库**。数据库不需要重建，已有数据不动。

适合这种场景：本地库是网盘（115、阿里云盘…）经 WebDAV 或 STRM 映射出来的，想做到

- 本地只放索引和小文件，播放时才去远端取原始音质
- 或者更进一步：**把网盘直链直接交给客户端**，服务器完全不占音频带宽

## 两种播放模式

| 模式 | 客户端看到 | 服务器带宽 | 兼容性 |
|---|---|---|---|
| `relay` | 只有 Navidrome | 下载 + 上传 | 所有客户端 |
| `redirect` | 302 到网盘 CDN | 只有一次 302（约 0ms） | 见下方兼容性表 |

```toml
EnablePathOverride = true
PS115Mode = "redirect"

[PathOverride]
"/music" = "webdav://user:pass@192.168.1.10:15222/音乐"
```

`PathOverride` 的值可以是本地目录，也可以是 `webdav://` / `webdavs://` / `http(s)://`。

### 客户端兼容性（实测）

| 客户端 | redirect 模式 | 依据 |
|---|---|---|
| 浏览器 `<audio>` / NavidromeUI | ✅ | `readyState=4`，时长正确 |
| LMP v1.12.0 | ✅ | 每首一次 302，随后直连 CDN |
| EchoSpace 2.0.2 (iOS) | ✅ | 95 次请求全 302、`responseSize=0`，播放正常 |
| Primuse 1.0 (iOS) | ❌ | 媒体会话的重定向委托直接 `return nil`，任何跳转都不跟；只能用 relay |

**关键在响应形状，不在状态码**：302 必须带空 body、音频 `Content-Type` 和 `Accept-Ranges: bytes`。
`http.Redirect` 默认写 ~300 字节 HTML body + `text/html`，部分播放器会把它当错误页面而不跟。

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

构建镜像：

```bash
make docker-image IMAGE_PLATFORMS=linux/amd64 DOCKER_TAG=navidrome:test
```

## 补丁做了什么

上游改动 **5 个文件 +40 / -6**，新增 2 个文件（上游不存在，永不冲突）：

| 文件 | 改动 |
|---|---|
| `core/stream/source.go`（新增，405 行） | 路径解析、远端源的 `ReadSeekCloser`、转码落盘 |
| `core/stream/ps115.go`（新增，152 行） | 解析网盘直链（走源站的 302，不读任何索引库） |
| `core/stream/media_streamer.go` | 拦截点 + 302 分支 + 转码入口 |
| `core/ffmpeg/ffmpeg.go` | 允许 URL 输入，远端源先落盘 |
| `conf/configuration.go` | `EnablePathOverride` / `PathOverride` / `PS115Mode` |
| `core/stream/decider.go` | 探测走 `resolveSource` |
| `core/archiver.go` | zip 批量下载走 `OpenSource` |

细节、验证数据、故障排查见 [docs/playback-redirect.md](docs/playback-redirect.md)。

## 上游更新后

```bash
git pull          # 或切到新 tag
./navidrome-diy.sh
```

补丁全部集中在脚本里（两个新文件的全文内嵌在脚本中），所以更新上游只需要重跑一次。

## 已知限制

- 只改播放侧，扫描仍要求本地存在文件（真实文件或 strm 占位）
- WebDAV 只支持 Basic 认证
- 网盘签名链接常有单链接大小上限（如 115 的 50 MB），`redirect` 模式下超大单曲会中途断开，`relay` 模式由服务器重新请求，不受影响
- 签名链接约 1 小时过期；长时间暂停后继续播放会失败，重新播放即可

## 许可

Navidrome 是 GPLv3，本补丁是其衍生作品，同样以 **GPLv3** 发布，见 [LICENSE](LICENSE)。
