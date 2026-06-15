package transfer

import "testing"

func TestComputeSpeed(t *testing.T) {
	// 1 秒内多传了 1MB → 速度约 1MB/s
	sp := computeSpeed(2_000_000, 1_000_000, 1.0)
	if sp != 1_000_000 {
		t.Fatalf("速度应为 1000000,得到 %d", sp)
	}
}

func TestComputeETA(t *testing.T) {
	// 还剩 5MB,速度 1MB/s → 5 秒
	eta := computeETA(10_000_000, 5_000_000, 1_000_000)
	if eta != 5 {
		t.Fatalf("ETA 应为 5,得到 %d", eta)
	}
	// 速度为 0 → ETA 0(未知)
	if computeETA(10, 0, 0) != 0 {
		t.Fatal("速度为 0 时 ETA 应为 0")
	}
}
