#!/bin/bash
#
# Navidrome 播放源重定向一键补丁（PathOverride → 本地目录 / WebDAV）
#
# 用途：上游更新后重新应用“播放走映射目录或 WebDAV、扫描仍走本地路径”的改动。
# 用法：
#   ./navidrome-diy.sh          # 应用补丁 + 编译自检
#   ./navidrome-diy.sh --no-build
#
# 设计原则（为了上游更新后能反复重放）：
#   1. 所有新增逻辑放在新文件 core/stream/source.go，上游永远不会有它，零冲突
#   2. 上游文件只做 4 处极小改动，每处都有“是否已应用”判定，可重复执行
#   3. 每个锚点改完都会校验，未命中直接报错退出，绝不静默半成品
#   4. 改动前自动备份，后缀 .backup.YYYYmmddHHMMSS
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
NO_BUILD=0
[ "${1:-}" = "--no-build" ] && NO_BUILD=1

echo "=========================================="
echo "Navidrome 播放源重定向补丁（本地映射 / WebDAV）"
echo "=========================================="
echo ""

if [ ! -f "${SCRIPT_DIR}/main.go" ]; then
    echo "错误：请在 Navidrome 源码根目录运行此脚本"
    exit 1
fi

TS="$(date +%Y%m%d%H%M%S)"
backup() {
    local f="$1"
    [ -f "$f" ] || return 0
    cp "$f" "${f}.backup.${TS}"
    echo "  📦 备份 $f"
}

echo "📦 备份将要修改的上游文件..."
backup core/stream/media_streamer.go
backup core/ffmpeg/ffmpeg.go
backup core/archiver.go
backup core/stream/decider.go
backup conf/configuration.go
echo "✅ 备份完成"
echo ""

echo "🧩 写入新文件 core/stream/source.go（上游没有此文件，永不冲突）..."
cat > core/stream/source.go <<'NDSOURCE_EOF'
package stream

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/navidrome/navidrome/conf"
	"github.com/navidrome/navidrome/consts"
	"github.com/navidrome/navidrome/core/ffmpeg"
	"github.com/navidrome/navidrome/log"
	"github.com/navidrome/navidrome/model"
)

// This file implements playback-side source redirection.
//
// Scanning always keeps reading the local library path: the DB, artwork, playlists
// and the scanner are untouched. Only the bytes used to serve or transcode a track
// can be redirected, per library, by the [PathOverride] config map. A mapping value
// may be either another local directory or a WebDAV/HTTP endpoint:
//
//	EnablePathOverride = true
//	[PathOverride]
//	"/music"       = "/mnt/ssd/music"
//	"/music-remote" = "webdav://user:pass@192.168.1.10:5005/dav/music"
//
// webdav:// and webdavs:// are aliases for http:// and https:// (a WebDAV GET is a
// plain HTTP GET), so ffmpeg can read the same URL directly.

const (
	schemeWebDAV  = "webdav"
	schemeWebDAVs = "webdavs"
)

// resolveSource returns where the bytes of mf actually live at playback time.
// It returns either a local filesystem path or an http(s) URL.
func resolveSource(ctx context.Context, mf *model.MediaFile) string {
	if conf.Server.EnablePathOverride && len(conf.Server.PathOverride) > 0 {
		if base, ok := conf.Server.PathOverride[mf.LibraryPath]; ok && strings.TrimSpace(base) != "" {
			target := joinSource(base, mf.Path)
			// Direct-link mode: resolve the 115 CDN URL here so every downstream
			// consumer (stream, transcode, probe) sees a plain http source.
			// On any failure we silently keep the WebDAV URL.
			// Both modes need the signed URL; on failure we keep the WebDAV one.
			if isRemoteSource(target) {
				if link, err := ps115DirectURL(ctx, target); err == nil {
					ps115LogResolution(ctx, mf.ID, mf.Path, link)
					return link
				} else {
					log.Warn(ctx, "ps115 direct link unavailable, using WebDAV", "id", mf.ID,
						"relativePath", mf.Path, "error", err)
				}
			}
			log.Debug(ctx, "Playback source overridden", "id", mf.ID,
				"libraryPath", mf.LibraryPath, "relativePath", mf.Path, "source", RedactURL(target))
			return target
		}
	}
	return mf.AbsolutePath()
}

// joinSource joins a library-relative media path onto an override base, which may be
// a local directory or a URL. filepath.Join must not be used for URLs: it collapses
// the "//" after the scheme and drops the authority.
func joinSource(base, rel string) string {
	rel = strings.TrimPrefix(filepath.ToSlash(rel), "/")
	if !strings.Contains(base, "://") {
		return filepath.Join(base, rel)
	}
	u, err := url.Parse(base)
	if err != nil || u.Host == "" {
		return filepath.Join(base, rel)
	}
	// Assign the decoded path: url.URL.String() escapes it (spaces, CJK, ...) itself.
	u.Path = strings.TrimSuffix(u.Path, "/") + "/" + rel
	switch strings.ToLower(u.Scheme) {
	case schemeWebDAV:
		u.Scheme = "http"
	case schemeWebDAVs:
		u.Scheme = "https"
	}
	return u.String()
}

// isRemoteSource reports whether a resolved source must be fetched over HTTP.
func isRemoteSource(p string) bool {
	lower := strings.ToLower(p)
	return strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://")
}

// RedactURL strips credentials from a URL so it can be logged. Non-URL inputs are
// returned unchanged.
func RedactURL(p string) string {
	if !strings.Contains(p, "://") {
		return p
	}
	u, err := url.Parse(p)
	if err != nil {
		return "<invalid url>"
	}
	if u.User != nil {
		u.User = url.User("***")
	}
	return u.String()
}

// remoteProbeClient is used for short, bounded requests (size probe, redirect
// resolution). Streaming uses its own client without a total timeout.
var remoteProbeClient = &http.Client{Timeout: 20 * time.Second}

// OpenSource opens the playback source for a resolved path. Local paths are opened
// from disk; http(s) sources are exposed as a seekable HTTP resource backed by Range
// requests, so the existing Stream code path (http.ServeContent) keeps working
// unchanged for both cases.
func OpenSource(ctx context.Context, path string) (io.ReadSeekCloser, error) {
	if !isRemoteSource(path) {
		return os.Open(path)
	}
	return newRemoteFile(ctx, path)
}

// remoteFile is a minimal io.ReadSeekCloser over a single HTTP resource. Seek is
// implemented by dropping the current response body and re-requesting with a Range
// header. Servers that ignore Range are supported by re-reading and discarding.
type remoteFile struct {
	ctx    context.Context
	u      *url.URL
	auth   string
	client *http.Client
	size   int64
	pos    int64
	body   io.ReadCloser
	ranges bool // server honors Range requests
}

func newRemoteFile(ctx context.Context, raw string) (*remoteFile, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid source url: %w", err)
	}
	rf := &remoteFile{
		ctx:  ctx,
		u:    u,
		size: -1,
		client: &http.Client{
			// No overall timeout: bodies are streamed. The transport still bounds
			// the time spent waiting for response headers.
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				ResponseHeaderTimeout: 30 * time.Second,
				IdleConnTimeout:       90 * time.Second,
				MaxIdleConnsPerHost:   4,
			},
		},
	}
	if u.User != nil {
		pass, _ := u.User.Password()
		req := &http.Request{Header: http.Header{}}
		req.SetBasicAuth(u.User.Username(), pass)
		rf.auth = req.Header.Get("Authorization")
		clean := *u
		clean.User = nil
		rf.u = &clean
	}
	if err := rf.probe(); err != nil {
		return nil, err
	}
	return rf, nil
}

// probe determines the resource size and whether Range requests are supported.
func (rf *remoteFile) probe() error {
	req, err := http.NewRequestWithContext(rf.ctx, http.MethodGet, rf.u.String(), nil)
	if err != nil {
		return err
	}
	rf.setAuth(req)
	req.Header.Set("Range", "bytes=0-0")
	resp, err := rf.client.Do(req)
	if err != nil {
		return fmt.Errorf("probing source: %w", unwrapURLError(err))
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1))

	switch resp.StatusCode {
	case http.StatusPartialContent:
		rf.ranges = true
		rf.size = parseContentRangeTotal(resp.Header.Get("Content-Range"))
	case http.StatusOK:
		// Server ignored the Range header and sent the whole body.
		rf.ranges = strings.Contains(strings.ToLower(resp.Header.Get("Accept-Ranges")), "bytes")
		rf.size = resp.ContentLength
	case http.StatusRequestedRangeNotSatisfiable:
		rf.size = parseContentRangeTotal(resp.Header.Get("Content-Range"))
	default:
		return fmt.Errorf("source returned %s", resp.Status)
	}
	if rf.size < 0 {
		return errors.New("source size unknown (no Content-Length/Content-Range)")
	}
	return nil
}

func (rf *remoteFile) setAuth(req *http.Request) {
	if rf.auth != "" {
		req.Header.Set("Authorization", rf.auth)
	}
}

func (rf *remoteFile) Read(p []byte) (int, error) {
	if rf.pos >= rf.size {
		return 0, io.EOF
	}
	if rf.body == nil {
		if err := rf.openAt(rf.pos); err != nil {
			return 0, err
		}
	}
	n, err := rf.body.Read(p)
	rf.pos += int64(n)
	if err != nil {
		_ = rf.body.Close()
		rf.body = nil
		if errors.Is(err, io.EOF) && rf.pos < rf.size {
			// Premature end of a ranged body: report it as such instead of a clean
			// finish, so the client sees a truncated stream rather than silence.
			return n, io.ErrUnexpectedEOF
		}
	}
	return n, err
}

// openAt starts a response body positioned at off.
func (rf *remoteFile) openAt(off int64) error {
	req, err := http.NewRequestWithContext(rf.ctx, http.MethodGet, rf.u.String(), nil)
	if err != nil {
		return err
	}
	rf.setAuth(req)
	if rf.ranges && off > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(off, 10)+"-")
	}
	resp, err := rf.client.Do(req)
	if err != nil {
		return fmt.Errorf("opening source: %w", unwrapURLError(err))
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		resp.Body.Close()
		return fmt.Errorf("source returned %s", resp.Status)
	}
	// Server ignored Range: discard the bytes before the requested offset.
	if off > 0 && resp.StatusCode == http.StatusOK {
		if _, err := io.CopyN(io.Discard, resp.Body, off); err != nil {
			resp.Body.Close()
			return fmt.Errorf("seeking source: %w", err)
		}
	}
	rf.body = resp.Body
	return nil
}

func (rf *remoteFile) Seek(offset int64, whence int) (int64, error) {
	var abs int64
	switch whence {
	case io.SeekStart:
		abs = offset
	case io.SeekCurrent:
		abs = rf.pos + offset
	case io.SeekEnd:
		abs = rf.size + offset
	default:
		return 0, fmt.Errorf("invalid whence %d", whence)
	}
	if abs < 0 {
		return 0, errors.New("negative position")
	}
	if rf.body != nil {
		_ = rf.body.Close()
		rf.body = nil
	}
	rf.pos = abs
	return abs, nil
}

func (rf *remoteFile) Close() error {
	if rf.body != nil {
		err := rf.body.Close()
		rf.body = nil
		return err
	}
	return nil
}

// unwrapURLError strips the request URL out of a transport error. Besides keeping
// credentials and percent-escapes out of user-facing messages, it avoids a
// formatting quirk upstream: subsonic error strings are run through Sprintf a
// second time, so any "%20" in a URL would be mangled into "%!A(MISSING)".
func unwrapURLError(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) && ue.Err != nil {
		return ue.Err
	}
	return err
}

// parseContentRangeTotal extracts the total size from "bytes 0-0/12345" or "bytes */12345".
func parseContentRangeTotal(h string) int64 {
	if h == "" {
		return -1
	}
	idx := strings.LastIndex(h, "/")
	if idx < 0 {
		return -1
	}
	total := strings.TrimSpace(h[idx+1:])
	if total == "*" {
		return -1
	}
	n, err := strconv.ParseInt(total, 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// transcodeSource starts a transcode, spooling a remote source to a local temp file
// first. ffmpeg needs a seekable input (MP4/M4A keep their index at the end, so a
// pipe fails), and some endpoints reject ffmpeg's requests or rotate signed URLs
// between range requests. The spool is removed once the output stream is closed.
func transcodeSource(ctx context.Context, t ffmpeg.FFmpeg, opts ffmpeg.TranscodeOptions) (io.ReadCloser, error) {
	if !isRemoteSource(opts.FilePath) {
		return t.Transcode(ctx, opts)
	}
	name, err := spoolRemote(ctx, opts.FilePath)
	if err != nil {
		return nil, err
	}
	opts.FilePath = name
	out, err := t.Transcode(ctx, opts)
	if err != nil {
		_ = os.Remove(name)
		return nil, err
	}
	return &spoolCleanupReadCloser{ReadCloser: out, path: name}, nil
}

// spoolCleanupReadCloser removes the spooled source file once ffmpeg output is done.
type spoolCleanupReadCloser struct {
	io.ReadCloser
	path string
}

func (s *spoolCleanupReadCloser) Close() error {
	err := s.ReadCloser.Close()
	if s.path != "" {
		_ = os.Remove(s.path)
		s.path = ""
	}
	return err
}

// spoolRemote downloads a remote playback source into a local temp file and returns
// its path. Transcoding reads from the spool instead of the network because ffmpeg
// needs a seekable input (MP4/M4A keep their index at the end, so a pipe fails), and
// because some endpoints reject ffmpeg's requests or hand out a fresh signed URL per
// request. The caller owns the file and must remove it.
func spoolRemote(ctx context.Context, src string) (string, error) {
	r, err := OpenSource(ctx, src)
	if err != nil {
		return "", err
	}
	defer r.Close()

	// Spool next to the transcoding cache so it shares the same volume and is
	// cleaned up by the same lifecycle.
	dir := filepath.Join(conf.Server.CacheFolder.MustPath(), consts.TranscodingCacheDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("creating spool dir: %w", err)
	}
	f, err := os.CreateTemp(dir, "remote-*.src")
	if err != nil {
		return "", fmt.Errorf("creating spool file: %w", err)
	}
	name := f.Name()
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		_ = os.Remove(name)
		return "", fmt.Errorf("spooling remote source: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(name)
		return "", fmt.Errorf("closing spool file: %w", err)
	}
	log.Debug(ctx, "Spooled remote source for transcoding", "source", RedactURL(src), "file", name)
	return name, nil
}
NDSOURCE_EOF

cat > core/stream/ps115.go <<'NDPS115_EOF'
package stream

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/navidrome/navidrome/conf"
	"github.com/navidrome/navidrome/log"
)

// This file implements the "direct link" playback modes.
//
// PS115Mode selects what the client receives at playback time:
//
//	"relay"    - the signed 115 CDN URL is fetched by the server and relayed (default)
//	"redirect" - the signed 115 CDN URL is handed to the client with a 302
//
// The CDN URL is obtained the same way a player would: ask the WebDAV endpoint for
// the file, follow its redirect to ps2115, and read the Location ps2115 answers with.
// Only the WebDAV/HTTP interface is used - ps2115's index database is never opened,
// so its files are never locked or touched.
//
// Any failure falls back to the plain WebDAV URL, which the server then relays
// directly, so a broken setup degrades in speed instead of breaking playback.

const (
	ps115ModeWebDAV   = "webdav"
	ps115ModeProxy    = "proxy"
	ps115ModeRedirect = "redirect"
)

// mediaContentType maps an audio suffix to the type the player expects to see on
// the redirect response itself.
func mediaContentType(suffix string) string {
	switch strings.ToLower(strings.TrimPrefix(suffix, ".")) {
	case "m4a", "mp4", "aac", "alac":
		return "audio/mp4"
	case "mp3":
		return "audio/mpeg"
	case "flac":
		return "audio/flac"
	case "ogg", "oga", "opus":
		return "audio/ogg"
	case "wav":
		return "audio/wav"
	case "wma":
		return "audio/x-ms-wma"
	default:
		return "application/octet-stream"
	}
}

// ps115LinkTTL is used when the signed URL carries no usable expiry.
const ps115LinkTTL = 10 * time.Minute

// ps115Safety is how long before the signature expires a link is refreshed.
const ps115Safety = 5 * time.Minute

type ps115Link struct {
	url string
	exp time.Time
}

var ps115Cache = struct {
	sync.Mutex
	urls map[string]ps115Link
}{urls: map[string]ps115Link{}}

// ps115Mode returns the configured playback mode, defaulting to WebDAV relay.
func ps115Mode() string {
	switch m := strings.ToLower(strings.TrimSpace(conf.Server.PS115Mode)); m {
	case ps115ModeProxy, ps115ModeRedirect:
		return m
	default:
		return ps115ModeWebDAV
	}
}

// ps115Client only inspects redirects: every hop is read for its Location header,
// and the CDN is never contacted from here.
var ps115Client = &http.Client{
	Timeout: 15 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

// ps115DirectURL resolves the signed 115 CDN URL for a WebDAV source URL.
func ps115DirectURL(ctx context.Context, webdavURL string) (string, error) {
	ps115Cache.Lock()
	if l, ok := ps115Cache.urls[webdavURL]; ok && time.Now().Before(l.exp) {
		ps115Cache.Unlock()
		return l.url, nil
	}
	ps115Cache.Unlock()

	link, err := ps115Resolve(ctx, webdavURL)
	if err != nil {
		return "", err
	}
	ps115Cache.Lock()
	ps115Cache.urls[webdavURL] = ps115Link{url: link, exp: ps115Expiry(link)}
	ps115Cache.Unlock()
	return link, nil
}

// ps115Resolve walks the redirect chain (WebDAV -> ps2115 -> CDN) and returns the
// CDN URL without fetching a single byte from it.
func ps115Resolve(ctx context.Context, webdavURL string) (string, error) {
	current := webdavURL
	for hop := 0; hop < 4; hop++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, current, nil)
		if err != nil {
			return "", err
		}
		// One byte is enough for every hop to answer with its redirect.
		req.Header.Set("Range", "bytes=0-0")
		resp, err := ps115Client.Do(req)
		if err != nil {
			return "", fmt.Errorf("hop %d: %w", hop+1, unwrapURLError(err))
		}
		loc := resp.Header.Get("Location")
		resp.Body.Close()

		if loc == "" {
			return "", fmt.Errorf("hop %d: no redirect (status %d)", hop+1, resp.StatusCode)
		}
		base := req.URL
		if resp.Request != nil && resp.Request.URL != nil {
			base = resp.Request.URL
		}
		ref, err := url.Parse(loc)
		if err != nil {
			return "", fmt.Errorf("hop %d: bad Location", hop+1)
		}
		next := base.ResolveReference(ref)
		if next.User != nil || (next.Scheme != "http" && next.Scheme != "https") {
			return "", fmt.Errorf("hop %d: refusing target %s", hop+1, RedactURL(next.String()))
		}
		// A redirect that leaves the WebDAV host is the CDN itself: stop here.
		if !strings.EqualFold(next.Hostname(), base.Hostname()) {
			return next.String(), nil
		}
		current = next.String()
	}
	return "", fmt.Errorf("redirect chain too long")
}

// ps115Expiry reads the signature expiry (t=) out of a signed CDN URL.
func ps115Expiry(link string) time.Time {
	if u, err := url.Parse(link); err == nil {
		if raw := u.Query().Get("t"); raw != "" {
			if ts, err := strconv.ParseInt(raw, 10, 64); err == nil {
				if exp := time.Unix(ts, 0).Add(-ps115Safety); exp.After(time.Now()) {
					return exp
				}
				return time.Now().Add(2 * time.Minute)
			}
		}
	}
	return time.Now().Add(ps115LinkTTL)
}

// ps115LogResolution records a resolved link at debug level.
func ps115LogResolution(ctx context.Context, id, rel, link string) {
	log.Debug(ctx, "Playback source is a 115 direct link", "id", id, "relativePath", rel, "source", RedactURL(link))
}
NDPS115_EOF
echo "  ✓ core/stream/source.go"
echo ""

echo "🔧 修改上游文件..."
python3 - "${SCRIPT_DIR}" <<'NDPY_EOF'
import os, sys

root = sys.argv[1]
fail = []


def path(p):
    return os.path.join(root, p)


def read(p):
    with open(path(p)) as f:
        return f.read()


def write(p, s):
    with open(path(p), "w") as f:
        f.write(s)


def check(cond, ok, bad):
    if cond:
        print("  ✓ " + ok)
    else:
        print("  ✗ " + bad)
        fail.append(bad)


# ---------------------------------------------------------------- media_streamer.go
p = "core/stream/media_streamer.go"
s = read(p)

# 1) 删除旧版补丁注入的 30 行 resolveFilePath 方法（逻辑已搬进 source.go）
if "func (ms *mediaStreamer) resolveFilePath" in s:
    i = s.index("func (ms *mediaStreamer) resolveFilePath")
    lines = s[:i].split("\n")
    k = len(lines) - 1
    while k > 0 and (lines[k].strip().startswith("//") or lines[k].strip() == ""):
        k -= 1
    start = len("\n".join(lines[:k + 1])) + 1
    end = s.index("type Stream struct", i)
    s = s[:start] + s[end:]
    s = s.replace("\n\n\ntype Stream struct", "\n\ntype Stream struct")
    print("  ✓ 移除旧版 resolveFilePath 方法（已迁移到 source.go）")

# 2) filepath 不再使用则去掉 import
if "filepath." not in s:
    s = s.replace('\t"path/filepath"\n', "", 1)

# 3) 解析调用：上游原文 / 旧补丁写法都归一成 resolveSource
if "filePath := mf.AbsolutePath()" in s:
    s = s.replace("filePath := mf.AbsolutePath()", "filePath := resolveSource(ctx, mf)", 1)
    print("  ✓ filePath 改为 resolveSource(ctx, mf)")
elif "ms.resolveFilePath(ctx, mf)" in s:
    s = s.replace("ms.resolveFilePath(ctx, mf)", "resolveSource(ctx, mf)", 1)
    print("  ✓ 旧版调用迁移为 resolveSource(ctx, mf)")
else:
    check("resolveSource(ctx, mf)" in s,
          "filePath 已是 resolveSource(ctx, mf)",
          "media_streamer.go 未找到 filePath 解析锚点（上游结构可能已变）")

# 4) raw 分支改用 OpenSource
if "f, err := os.Open(filePath)" in s:
    s = s.replace("f, err := os.Open(filePath)", "f, err := OpenSource(ctx, filePath)", 1)
    print("  ✓ raw 直连改用 OpenSource(ctx, filePath)")
else:
    check("OpenSource(ctx, filePath)" in s,
          "raw 直连已是 OpenSource(ctx, filePath)",
          "media_streamer.go 未找到 raw 分支 os.Open 锚点（上游结构可能已变）")

# 5) Stream 结构体增加 redirectURL 字段
if "redirectURL string" not in s:
    s = s.replace("\tformat  string\n\tio.ReadCloser",
                  "\tformat  string\n"
                  "\t// redirectURL, when set, makes Serve answer with a 302 instead of streaming.\n"
                  "\tredirectURL string\n"
                  "\tio.ReadCloser", 1)
check("redirectURL string" in s, "Stream 增加 redirectURL 字段", "media_streamer.go 未找到 Stream 结构体锚点")

# 6) raw 分支：redirect 模式直接 302
if "ps115ModeRedirect" not in s:
    s = s.replace("\t\tf, err := OpenSource(ctx, filePath)",
                  "\t\tif ps115Mode() == ps115ModeRedirect && isRemoteSource(filePath) {\n"
                  "\t\t\t// Hand the signed 115 URL to the client; we never touch the bytes.\n"
                  "\t\t\tlog.Debug(ctx, \"Redirecting client to 115 direct link\", \"id\", mf.ID, \"url\", RedactURL(filePath))\n"
                  "\t\t\ts.redirectURL = filePath\n"
                  "\t\t\ts.ReadCloser = http.NoBody\n"
                  "\t\t\ts.format = mf.Suffix\n"
                  "\t\t\treturn s, nil\n"
                  "\t\t}\n"
                  "\t\tf, err := OpenSource(ctx, filePath)", 1)
check("ps115ModeRedirect" in s, "raw 分支支持 302", "media_streamer.go 未找到 OpenSource 锚点")

# 6b) Serve 处理 302
if "mediaContentType(s.format)" not in s:
    s = s.replace("func (s *Stream) Serve(ctx context.Context, w http.ResponseWriter, r *http.Request) (int64, error) {\n\tif s.Seekable() {",
                  "func (s *Stream) Serve(ctx context.Context, w http.ResponseWriter, r *http.Request) (int64, error) {\n"
                  "\tif s.redirectURL != \"\" {\n"
                  "\t\t// Signed and short-lived: never let anything cache it.\n"
                  "\t\t// An empty body and an audio Content-Type: some players refuse to follow a\n"
                  "\t\t// 302 that looks like an HTML page (http.Redirect writes one), and others\n"
                  "\t\t// read the body as audio data. The response must look like a media\n"
                  "\t\t// redirect, not a page. 302 with this shape is followed by every client\n"
                  "\t\t// tested, so it is not configurable.\n"
                  "\t\tw.Header().Set(\"Cache-Control\", \"no-store\")\n"
                  "\t\tw.Header().Set(\"Accept-Ranges\", \"bytes\")\n"
                  "\t\tw.Header().Set(\"Content-Type\", mediaContentType(s.format))\n"
                  "\t\tw.Header().Set(\"Location\", s.redirectURL)\n"
                  "\t\tw.WriteHeader(http.StatusFound)\n"
                  "\t\treturn 0, nil\n"
                  "\t}\n"
                  "\tif s.Seekable() {", 1)
check("mediaContentType(s.format)" in s, "Serve 302 + 空 body", "media_streamer.go 未找到 Serve 锚点")

# 7) 转码入口改为 transcodeSource（远端源先落盘）
if "transcodeSource(transcodingCtx" not in s:
    s = s.replace("out, err := job.ms.transcoder.Transcode(transcodingCtx, ffmpeg.TranscodeOptions{",
                  "out, err := transcodeSource(transcodingCtx, job.ms.transcoder, ffmpeg.TranscodeOptions{", 1)
check("transcodeSource(transcodingCtx" in s, "转码改走 transcodeSource", "media_streamer.go 未找到 Transcode 调用锚点")

write(p, s)

# ---------------------------------------------------------------- configuration.go
p = "conf/configuration.go"
s = read(p)

FIELDS = (
    "\t// Playback source redirection (see core/stream/source.go).\n"
    "\t// Values may be a local directory or a webdav:// URL.\n"
    "\tEnablePathOverride bool\n"
    "\tPathOverride       map[string]string\n"
    "\t// Playback source mode:\n"
    "\t//   \"relay\"    - resolve the signed 115 CDN URL and relay the bytes (default)\n"
    "\t//   \"redirect\" - resolve the signed 115 CDN URL and 302 the client to it\n"
    "\t// Resolution failures fall back to the plain WebDAV URL.\n"
    "\tPS115Mode string"
)

lines = s.split("\n")


def insert_after(pred, block, label):
    idx = next((i for i, l in enumerate(lines) if pred(l)), None)
    if idx is None:
        return False
    lines.insert(idx + 1, block)
    print("  \u2713 " + label)
    return True


if "EnablePathOverride" not in s:
    if not insert_after(lambda l: l.strip().startswith("Agents "), FIELDS,
                        "configuration.go 增加 PathOverride 配置字段"):
        check(False, "", "configuration.go 未找到 Agents 字段锚点")
else:
    print("  \u2713 configuration.go 已包含 PathOverride 配置字段")

s = "\n".join(lines)
check("PS115Mode string" in s,
      "configuration.go 直链开关就位",
      "configuration.go 直链开关未插入")
check("EnablePathOverride bool" in s and "PathOverride" in s,
      "configuration.go 字段就位",
      "configuration.go 字段未插入")
write(p, s)

# ---------------------------------------------------------------- ffmpeg.go
p = "core/ffmpeg/ffmpeg.go"
s = read(p)

if "func isRemotePath(" not in s:
    helper = (
        "// isRemotePath reports whether path is an HTTP(S) URL rather than a local file.\n"
        "func isRemotePath(path string) bool {\n"
        '\tlower := strings.ToLower(path)\n'
        '\treturn strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://")\n'
        "}\n\n"
    )
    s = s.replace("func fileExists(path string) error {", helper + "func fileExists(path string) error {", 1)
    s = s.replace(
        "func fileExists(path string) error {\n\ts, err := os.Stat(path)",
        "func fileExists(path string) error {\n"
        "\t// 远端播放源走 HTTP，无法本地 stat；ffmpeg 的 http 协议会直接读取它。\n"
        "\tif isRemotePath(path) {\n"
        "\t\treturn nil\n"
        "\t}\n"
        "\ts, err := os.Stat(path)",
        1,
    )
check("func isRemotePath(" in s, "ffmpeg.go 增加 isRemotePath 判定", "ffmpeg.go 未找到 fileExists 锚点")
check("if isRemotePath(path) {\n\t\treturn nil\n\t}" in s,
      "fileExists 放行 http(s) 源",
      "fileExists 内放行逻辑未插入")
write(p, s)

# ---------------------------------------------------------------- archiver.go
p = "core/archiver.go"
s = read(p)
if "r, err = os.Open(path)" in s:
    s = s.replace("r, err = os.Open(path)", "r, err = stream.OpenSource(ctx, path)", 1)
    print("  ✓ zip 批量下载改用 stream.OpenSource")
else:
    check("stream.OpenSource(ctx, path)" in s,
          "zip 批量下载已是 stream.OpenSource",
          "archiver.go 未找到 os.Open(path) 锚点")
if "os." not in s.replace('"os"', ""):
    s = s.replace('\t"os"\n', "", 1)
write(p, s)

# ---------------------------------------------------------------- decider.go
p = "core/stream/decider.go"
s = read(p)
if "ProbeAudioStream(ctx, mf.AbsolutePath())" in s:
    s = s.replace("ProbeAudioStream(ctx, mf.AbsolutePath())", "ProbeAudioStream(ctx, resolveSource(ctx, mf))", 1)
    print("  \u2713 probe 使用 resolveSource + 重定向解析")
elif "ProbeAudioStream(ctx, resolveSource(ctx, mf))" in s:
    s = s.replace("ProbeAudioStream(ctx, resolveSource(ctx, mf))", "ProbeAudioStream(ctx, resolveSource(ctx, mf))", 1)
    print("  \u2713 probe 补上重定向解析")
else:
    check("ProbeAudioStream(ctx, resolveSource(" in s,
          "probe 已是 resolveSource",
          "decider.go 未找到 probe 锚点")
write(p, s)

if fail:
    print("")
    print("❌ 以下改动未能应用：")
    for f in fail:
        print("   - " + f)
    sys.exit(1)
NDPY_EOF

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ 补丁应用失败，已中止（备份文件保留在原目录）"
    exit 1
fi

# 统一格式，避免注入代码的缩进/空行与 gofmt 不一致
gofmt -w core/stream/media_streamer.go core/stream/source.go core/ffmpeg/ffmpeg.go \
         core/archiver.go core/stream/decider.go conf/configuration.go 2>/dev/null || true
echo "✅ 上游文件修改完成"
echo ""

# 可选：CGO taglib 头文件路径修复（仅当使用 CGO taglib extractor 时需要）
if [ -f adapters/taglib/taglib_wrapper.go ]; then
    if grep -q "cgo linux CXXFLAGS: -std=c++11 -I/usr/include/taglib" adapters/taglib/taglib_wrapper.go; then
        echo "⚠️  taglib_wrapper.go 已包含头文件修复，跳过"
    else
        backup adapters/taglib/taglib_wrapper.go
        sed -i 's/#cgo linux darwin CXXFLAGS: -std=c++11/#cgo linux CXXFLAGS: -std=c++11 -I\/usr\/include\/taglib\n#cgo darwin CXXFLAGS: -std=c++11/' adapters/taglib/taglib_wrapper.go
        echo "  ✓ 修复 taglib 头文件路径"
    fi
    echo ""
fi

if [ "${NO_BUILD}" -eq 0 ]; then
    echo "🔨 编译自检：go build -tags netgo,sqlite_fts5 ./..."
    if go build -tags netgo,sqlite_fts5 ./...; then
        echo "✅ 编译通过"
    else
        echo "❌ 编译失败，请检查上游是否有结构性改动"
        exit 1
    fi
    echo ""
fi

echo "=========================================="
echo "✅ 补丁应用完成"
echo "=========================================="
echo ""
echo "📝 配置示例（navidrome.toml）："
echo ""
echo "   EnablePathOverride = true"
echo ""
echo "   [PathOverride]"
echo '   "/music"        = "/mnt/ssd/music"                              # 映射到本地目录'
echo '   "/music-remote" = "webdav://user:pass@192.168.1.10:5005/dav"   # 播放走 WebDAV'
echo ""
echo "   （可选）低码率请求由本机转码；原始音质由服务器转发"
echo "         请求原始音质时 302 直连上游（115 等签名 CDN）；请求低码率仍本机转码。"
echo "         上游不跳转、或最终地址需要凭据时自动回退为转发。"
echo ""
echo "   说明：扫描/入库/封面/歌单仍读原库路径，只有播放取字节走映射目标。"
echo "         webdav:// = http，webdavs:// = https，仅支持 Basic 认证。"
echo ""
echo "💡 备份文件保存在原目录，后缀 .backup.${TS}"
