// Package qrcode 把文本生成为二维码 PNG 的 base64 dataURL,供前端 <img> 直接显示。
package qrcode

import (
	"encoding/base64"

	qr "github.com/skip2/go-qrcode"
)

// DataURL 把 content 生成 size 像素见方的二维码,返回 data:image/png;base64,... 字符串。
func DataURL(content string, size int) (string, error) {
	png, err := qr.Encode(content, qr.Medium, size)
	if err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), nil
}
