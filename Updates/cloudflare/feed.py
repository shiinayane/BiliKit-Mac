"""Stage/validate public Sparkle metadata; never generate or read signing keys."""
import argparse
import base64
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"s": SPARKLE}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode(value, length):
    data = base64.b64decode(value, validate=True)
    require(len(data) == length, "签名或公钥长度不正确")
    return data


def verify(public_key, signature, data):
    decode(public_key, 32)
    decode(signature, 64)
    result = subprocess.run(
        ["node", str(ROOT / "verify.mjs")],
        input=json.dumps({"publicKey": public_key, "signature": signature,
                          "content": base64.b64encode(data).decode()}),
        text=True, capture_output=True,
    )
    require(result.returncode == 0, "Ed25519 公钥验签失败")


def validate_feed(data, config, archives=None):
    require(len(data) <= 1024 * 1024, "appcast 超过 1 MiB 本地上限")
    decode(config["publicEDKey"], 32)
    require(config["feedURL"] == "https://updates.shiinayane.com/appcast.xml",
            "feed 与候选 Cloudflare 路由不一致；变更域名需同步 App 与部署配置")
    # Exact output envelope from Sparkle 2.9.6 common_cli/Signing.swift.
    marker = b"<!-- sparkle-signatures:\n"
    require(data.count(marker) == 1, "必须包含唯一的 Sparkle feed 签名")
    content, block = data.split(marker)
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n", block)
    require(match is not None, "feed 签名封装不是固定版本官方工具的输出")
    require(int(match[2]) == len(content), "feed 签名长度不匹配")
    verify(config["publicEDKey"], match[1].decode(), content)
    require(b"<!DOCTYPE" not in content and b"<!ENTITY" not in content, "不接受 XML DTD/entity")
    root = ET.fromstring(content)
    require(root.tag == "rss" and root.attrib.get("version") == "2.0", "需要 RSS 2.0")
    require(len(root.findall("channel")) == 1, "需要单一 channel")
    items = root.findall("channel/item")
    # First release uses full immutable GitHub assets and no remote release notes.
    require(not root.findall(".//s:deltas", NS), "当前发布流程只允许完整包")
    require(not root.findall(".//s:releaseNotesLink", NS), "请使用内嵌发布说明")
    require(not root.findall(".//s:fullReleaseNotesLink", NS), "请使用内嵌发布说明")
    versions = set()
    for item in items:
        version = item.findtext("s:version", namespaces=NS)
        require(version is not None and re.fullmatch(r"[1-9][0-9]*", version), "需要正整数 build")
        require(int(version) >= 2 and version not in versions, "build 必须唯一且至少为 2")
        versions.add(version)
        require(item.findtext("s:minimumSystemVersion", namespaces=NS) == "15.0", "最低系统必须为 15.0")
        enclosures = item.findall("enclosure")
        require(len(enclosures) == 1, "每个更新项需要一个完整安装包")
        enclosure = enclosures[0]
        # Sparkle prefers the legacy enclosure attribute over the item element.
        require(enclosure.get(f"{{{SPARKLE}}}version", version) == version,
                "enclosure 与 item 的 build 必须完全一致")
        url = urlsplit(enclosure.attrib["url"])
        require(url.scheme == "https" and url.netloc == "github.com" and not url.query and not url.fragment,
                "安装包必须来自无凭据的 GitHub HTTPS 地址")
        parts = url.path.split("/")
        require(len(parts) == 7 and parts[1:5] == ["shiinayane", "BiliKit-Mac", "releases", "download"],
                "安装包必须属于批准的仓库 release asset")
        require(parts[5] and not parts[5].startswith("untagged-") and parts[5] != "latest", "不接受草稿或可变 tag")
        filename = unquote(parts[6])
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.dmg", filename), "只允许简单文件名的 DMG")
        signature = enclosure.attrib[f"{{{SPARKLE}}}edSignature"]
        decode(signature, 64)
        length = int(enclosure.attrib["length"])
        require(length > 0, "安装包长度无效")
        if archives is not None:
            archive = archives / filename
            require(archive.is_file() and not archive.is_symlink(), "缺少本地完整安装包")
            require(archive.stat().st_size == length, "安装包长度不匹配")
            verify(config["publicEDKey"], signature, archive.read_bytes())
    return len(items)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate")
    stage = commands.add_parser("stage")
    stage.add_argument("--feed", type=Path, required=True)
    stage.add_argument("--app", type=Path, required=True, help="新导出的 Developer ID App")
    stage.add_argument("--archives", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads((ROOT / "release.json").read_text())
    public = ROOT / "public"
    require(not public.is_symlink(), "public 不得为符号链接")
    for path in public.iterdir():
        require(path.name in {"_headers", "appcast.xml"} and path.is_file() and not path.is_symlink(),
                "public 只允许 _headers 和 appcast.xml，不允许目录、凭据或安装包")
    if args.command == "stage":
        info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == "com.shiinayane.BiliKit", "App 身份不一致")
        require(info.get("BiliKitUpdaterEnabled") is True, "App 更新器未启用")
        require(info.get("SURequireSignedFeed") is True and info.get("SUVerifyUpdateBeforeExtraction") is True,
                "App 必须强制 feed 与归档验签")
        require(info.get("SUSignedFeedFailureExpirationInterval") == 0, "feed 签名失败不得超时降级")
        require(info.get("SUFeedURL") == config["feedURL"], "App 与部署 feed 不一致")
        require(info.get("SUPublicEDKey") == config["publicEDKey"], "App 与部署公钥不一致")
        for command in [
            ["codesign", "--verify", "--deep", "--strict", str(args.app)],
            ["spctl", "--assess", "--type", "execute", str(args.app)],
            ["xcrun", "stapler", "validate", str(args.app)],
        ]:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        data = args.feed.read_bytes()
        count = validate_feed(data, config, args.archives)
        with tempfile.NamedTemporaryFile(dir=public, delete=False) as target:
            target.write(data)
            temporary = Path(target.name)
        temporary.replace(public / "appcast.xml")
        print(f"已原样暂存 {count} 个已验签更新项；未上传或部署。")
    else:
        count = validate_feed((public / "appcast.xml").read_bytes(), config)
        print(f"{count} 个更新项：feed 公钥验签与静态上传边界通过。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError):
        sys.exit("更新源验证失败：配置、签名或输入不符合要求；未部署。")
