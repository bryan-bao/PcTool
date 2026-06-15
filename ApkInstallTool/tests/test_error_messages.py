from apk_installer.error_messages import translate


def test_success():
    assert translate("Performing Streamed Install\nSuccess") == "安装成功"


def test_signature_conflict():
    raw = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: ...]"
    msg = translate(raw)
    assert "签名" in msg
    assert "卸载" in msg


def test_version_downgrade():
    raw = "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]"
    assert "低版本" in translate(raw)


def test_no_device():
    raw = "adb: no devices/emulators found"
    assert "没有检测到设备" in translate(raw)


def test_unauthorized():
    raw = "adb: device unauthorized."
    assert "授权" in translate(raw)


def test_unknown_failure_keeps_raw():
    raw = "Failure [INSTALL_FAILED_SOMETHING_NEW]"
    msg = translate(raw)
    assert "安装失败" in msg
    assert "INSTALL_FAILED_SOMETHING_NEW" in msg
