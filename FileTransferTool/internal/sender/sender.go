// Package sender 实现"主动把本地文件发送到对端"的客户端逻辑,
// 用于电脑↔电脑互传。它复用对端 server 的 /api/offer、/api/upload/status、/api/upload 接口。
package sender

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"

	"filetransfer/internal/ratelimit"
	"filetransfer/internal/transfer"
)

type offerFile struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	RelPath    string `json:"relPath"`
	TotalBytes int64  `json:"totalBytes"`
}

type offerReq struct {
	Peer  string      `json:"peer"`
	Files []offerFile `json:"files"`
}

// SendFile 把 localPath 发送到 baseURL(对端服务地址,如 http://192.168.1.5:5686)。
// t 是本机的发送任务(用于上报进度);global/taskLim 是限速器(可为 nil);touch 进度回调(可为 nil)。
func SendFile(baseURL, peer string, t *transfer.Task, localPath string, global, taskLim *ratelimit.Limiter, touch func()) error {
	fi, err := os.Stat(localPath)
	if err != nil {
		return err
	}
	t.TotalBytes = fi.Size()

	// 1) 先 offer,告诉对端将要传的文件(对端会弹出任务,可点同意/拒绝)
	ob, _ := json.Marshal(offerReq{Peer: peer, Files: []offerFile{
		{ID: t.ID, Name: t.Name, RelPath: t.RelPath, TotalBytes: fi.Size()},
	}})
	if resp, err := http.Post(baseURL+"/api/offer", "application/json", bytes.NewReader(ob)); err != nil {
		return fmt.Errorf("连接对端失败: %w", err)
	} else {
		resp.Body.Close()
	}

	// 2) 查询对端已收到的偏移(断点续传)
	var offset int64
	if r, err := http.Get(baseURL + "/api/upload/status?id=" + t.ID); err == nil {
		var st struct {
			Offset int64 `json:"offset"`
		}
		json.NewDecoder(r.Body).Decode(&st)
		r.Body.Close()
		offset = st.Offset
	}

	// 3) 打开本地文件并定位到续传偏移
	f, err := os.Open(localPath)
	if err != nil {
		return err
	}
	defer f.Close()
	if offset > 0 {
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return err
		}
	}
	t.SetTransferred(offset)

	// 4) 限速读 + 进度统计,PUT 给对端
	reader := ratelimit.NewLimitedReader(f, taskLim, global)
	pr := &progressReader{r: reader, t: t, touch: touch}

	req, _ := http.NewRequest("PUT", baseURL+"/api/upload?id="+t.ID, pr)
	req.Header.Set("Content-Range", fmt.Sprintf("bytes %d-/%d", offset, fi.Size()))
	req.ContentLength = fi.Size() - offset
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("传输中断: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("对端返回状态 %d", resp.StatusCode)
	}
	return nil
}

// progressReader 在读取时累加已发送字节并回调上报。
type progressReader struct {
	r     io.Reader
	t     *transfer.Task
	touch func()
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.t.AddTransferred(int64(n))
		if p.touch != nil {
			p.touch()
		}
	}
	return n, err
}
