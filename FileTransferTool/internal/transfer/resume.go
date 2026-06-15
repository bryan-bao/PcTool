package transfer

import (
	"os"
	"path/filepath"
)

// partSuffix 是接收中临时文件的后缀。
const partSuffix = ".part"

// ResumeOffset 返回 dest 对应 .part 文件已有的大小(即续传起点);无则返回 0。
func ResumeOffset(dest string) (int64, error) {
	fi, err := os.Stat(dest + partSuffix)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return fi.Size(), nil
}

// OpenForResume 打开(或创建)dest 的 .part 文件,定位到末尾以便追加写入。
// 自动创建所需的父目录。返回文件句柄与当前偏移。
func OpenForResume(dest string) (*os.File, int64, error) {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return nil, 0, err
	}
	f, err := os.OpenFile(dest+partSuffix, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, 0, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	return f, fi.Size(), nil
}

// Finalize 在接收完成后,把 dest.part 改名为 dest。
func Finalize(dest string) error {
	return os.Rename(dest+partSuffix, dest)
}
