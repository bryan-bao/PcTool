package sender

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

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

// SendFile uploads localPath to baseURL and reports progress through t.
func SendFile(baseURL, peer string, t *transfer.Task, localPath string, global, taskLim *ratelimit.Limiter, touch func()) error {
	fi, err := os.Stat(localPath)
	if err != nil {
		return err
	}
	t.TotalBytes = fi.Size()

	ob, _ := json.Marshal(offerReq{Peer: peer, Files: []offerFile{
		{ID: t.ID, Name: t.Name, RelPath: t.RelPath, TotalBytes: fi.Size()},
	}})
	if resp, err := http.Post(baseURL+"/api/offer", "application/json", bytes.NewReader(ob)); err != nil {
		return fmt.Errorf("connect peer failed: %w", err)
	} else if err := expectOK(resp); err != nil {
		return err
	}

	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		offset, err := uploadOffset(baseURL, t.ID)
		if err != nil {
			return err
		}
		if offset > fi.Size() {
			return fmt.Errorf("invalid peer offset: %d > %d", offset, fi.Size())
		}

		status, body, err := uploadFromOffset(baseURL, t, localPath, fi.Size(), offset, global, taskLim, touch)
		if err != nil {
			return err
		}
		if status == http.StatusOK {
			return nil
		}

		lastErr = fmt.Errorf("peer returned status %d: %s", status, body)
		if status == http.StatusConflict || status >= http.StatusInternalServerError {
			continue
		}
		return lastErr
	}
	return lastErr
}

func uploadOffset(baseURL, id string) (int64, error) {
	resp, err := http.Get(baseURL + "/api/upload/status?id=" + id)
	if err != nil {
		return 0, fmt.Errorf("query upload offset failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, responseError(resp)
	}
	var st struct {
		Offset int64 `json:"offset"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		return 0, fmt.Errorf("decode upload offset failed: %w", err)
	}
	return st.Offset, nil
}

func uploadFromOffset(baseURL string, t *transfer.Task, localPath string, total, offset int64, global, taskLim *ratelimit.Limiter, touch func()) (int, string, error) {
	f, err := os.Open(localPath)
	if err != nil {
		return 0, "", err
	}
	defer f.Close()
	if offset > 0 {
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return 0, "", err
		}
	}
	t.SetTransferred(offset)
	if touch != nil {
		touch()
	}

	reader := ratelimit.NewLimitedReader(f, taskLim, global)
	pr := &progressReader{r: reader, t: t, touch: touch}
	req, _ := http.NewRequest("PUT", baseURL+"/api/upload?id="+t.ID, pr)
	req.Header.Set("Content-Range", fmt.Sprintf("bytes %d-/%d", offset, total))
	req.ContentLength = total - offset
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("transfer interrupted: %w", err)
	}
	defer resp.Body.Close()
	body := readResponseBody(resp)
	return resp.StatusCode, body, nil
}

func expectOK(resp *http.Response) error {
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	return responseError(resp)
}

func responseError(resp *http.Response) error {
	return fmt.Errorf("peer returned status %d: %s", resp.StatusCode, readResponseBody(resp))
}

func readResponseBody(resp *http.Response) string {
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	msg := strings.TrimSpace(string(b))
	if msg == "" {
		msg = http.StatusText(resp.StatusCode)
	}
	return msg
}

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
