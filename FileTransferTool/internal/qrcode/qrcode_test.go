package qrcode

import (
	"strings"
	"testing"
)

func TestDataURL_PNGPrefix(t *testing.T) {
	url, err := DataURL("http://192.168.1.5:8080/?t=abc", 256)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(url, "data:image/png;base64,") {
		t.Fatalf("应为 PNG dataURL,得到前缀: %.30s", url)
	}
	if len(url) < 100 {
		t.Fatal("dataURL 看起来太短,可能没生成图")
	}
}
