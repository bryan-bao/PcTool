"""程序入口:启动界面,缺依赖时给出中文提示。"""

import sys


def main():
    try:
        from apk_installer.ui import App
    except ModuleNotFoundError as e:
        print("缺少依赖,请先运行:pip install -r requirements.txt")
        print(f"详细:{e}")
        sys.exit(1)
    App().run()


if __name__ == "__main__":
    main()
