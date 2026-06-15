from unittest.mock import patch
from apk_installer import adb_wrapper
from apk_installer.adb_wrapper import Device


def test_find_adb_prefers_bundled(tmp_path, monkeypatch):
    # 模拟存在随附的 platform-tools/adb.exe
    bundled = tmp_path / "platform-tools"
    bundled.mkdir()
    exe = bundled / "adb.exe"
    exe.write_text("")
    monkeypatch.setattr(adb_wrapper, "_BUNDLED_ADB", exe)
    assert adb_wrapper.find_adb() == str(exe)


def test_find_adb_falls_back_to_path(monkeypatch):
    # 随附的不存在时,回退到 "adb"
    missing = adb_wrapper.Path("does/not/exist/adb.exe")
    monkeypatch.setattr(adb_wrapper, "_BUNDLED_ADB", missing)
    assert adb_wrapper.find_adb() == "adb"


def test_list_devices_parses_output():
    sample = (
        "List of devices attached\n"
        "ABC123    device product:p model:Pixel_5 device:d\n"
        "XYZ789    unauthorized\n"
        "\n"
    )
    with patch.object(adb_wrapper, "_run", return_value=(0, sample, "")):
        devices = adb_wrapper.list_devices()
    assert devices == [
        Device(serial="ABC123", model="Pixel_5", status="device"),
        Device(serial="XYZ789", model="(未授权)", status="unauthorized"),
    ]


def test_list_devices_empty():
    with patch.object(adb_wrapper, "_run", return_value=(0, "List of devices attached\n\n", "")):
        assert adb_wrapper.list_devices() == []


def test_install_apk_success():
    with patch.object(adb_wrapper, "_run", return_value=(0, "Performing Streamed Install\nSuccess\n", "")):
        result = adb_wrapper.install_apk("ABC123", "C:/x/app.apk")
    assert result.ok is True
    assert result.message == "安装成功"


def test_install_apk_failure_translated():
    raw = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"
    with patch.object(adb_wrapper, "_run", return_value=(1, raw, "")):
        result = adb_wrapper.install_apk("ABC123", "C:/x/app.apk")
    assert result.ok is False
    assert "签名" in result.message


def test_install_apk_builds_correct_command():
    captured = {}

    def fake_run(args, timeout=120):
        captured["args"] = args
        return (0, "Success", "")

    with patch.object(adb_wrapper, "_run", side_effect=fake_run):
        adb_wrapper.install_apk("ABC123", "C:/x/app.apk")
    assert captured["args"] == ["-s", "ABC123", "install", "-r", "C:/x/app.apk"]


def test_pair_wifi_success():
    with patch.object(adb_wrapper, "_run", return_value=(0, "Successfully paired to 192.168.1.5:37000", "")):
        result = adb_wrapper.pair_wifi("192.168.1.5", "37000", "123456")
    assert result.ok is True
    assert "配对成功" in result.message


def test_pair_wifi_builds_command():
    captured = {}

    def fake_run(args, timeout=120):
        captured["args"] = args
        return (0, "Successfully paired", "")

    with patch.object(adb_wrapper, "_run", side_effect=fake_run):
        adb_wrapper.pair_wifi("192.168.1.5", "37000", "123456")
    assert captured["args"] == ["pair", "192.168.1.5:37000", "123456"]


def test_connect_wifi_success():
    with patch.object(adb_wrapper, "_run", return_value=(0, "connected to 192.168.1.5:5555", "")):
        result = adb_wrapper.connect_wifi("192.168.1.5", "5555")
    assert result.ok is True
    assert "连接成功" in result.message


def test_connect_wifi_failure():
    with patch.object(adb_wrapper, "_run", return_value=(1, "", "failed to connect to 192.168.1.5:5555")):
        result = adb_wrapper.connect_wifi("192.168.1.5", "5555")
    assert result.ok is False
    assert "连接失败" in result.message
