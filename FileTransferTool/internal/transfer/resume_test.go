package transfer

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResumeOffset_NoPartFile_IsZero(t *testing.T) {
	dir := t.TempDir()
	off, err := ResumeOffset(filepath.Join(dir, "a.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if off != 0 {
		t.Fatalf("无 .part 文件时偏移应为 0,得到 %d", off)
	}
}

func TestResumeOffset_ExistingPart_ReturnsSize(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "a.bin")
	if err := os.WriteFile(dest+".part", []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	off, err := ResumeOffset(dest)
	if err != nil {
		t.Fatal(err)
	}
	if off != 5 {
		t.Fatalf("偏移应为 5,得到 %d", off)
	}
}

func TestOpenForResume_AppendsAtOffset(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "sub", "a.bin") // 目录不存在,应自动建
	f, off, err := OpenForResume(dest)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if off != 0 {
		t.Fatalf("新文件偏移应为 0,得到 %d", off)
	}
	if _, err := f.WriteString("world"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dest + ".part"); err != nil {
		t.Fatalf(".part 文件应存在: %v", err)
	}
}

func TestFinalize_RenamesPartToDest(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "a.bin")
	if err := os.WriteFile(dest+".part", []byte("done"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Finalize(dest); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dest); err != nil {
		t.Fatalf("最终文件应存在: %v", err)
	}
	if _, err := os.Stat(dest + ".part"); !os.IsNotExist(err) {
		t.Fatal(".part 文件应已被改名删除")
	}
}
