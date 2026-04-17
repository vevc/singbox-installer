# singbox-installer

一个面向个人使用的 `sing-box` 一键安装脚本（Linux + systemd），支持按**用户名分流**（`auth_user`）并可选将指定用户的流量转发到自定义 **SOCKS5 出站**。同时支持 **Cloudflare Tunnel（Argo）** 为 VLESS+WS 提供公网入口。

## 功能

- **自动下载并安装** `sing-box`（默认固定版本，可通过参数指定或使用 `latest`）
- **按需启用协议**（端口非 0 才启用）
  - **VLESS + WS**
  - **HY2**（`hysteria2`）
  - **TUIC**
- **NAT VPS 端口映射**
  - 端口参数支持 `公网端口:监听端口` 格式（类似 Docker），如 `--hy2-port 28443:8443`
  - 订阅链接使用公网端口，`config.json` 使用监听端口
- **多用户管理**
  - `--user <name[:uuid]>` 可重复添加用户（uuid 可省略自动生成）
  - `--user-socks5 name=host:port[:username:password]` 为指定用户绑定 SOCKS5 出站
  - 服务端使用 `route.rules[].auth_user` 按用户名分流到不同 outbound
- **自动生成配置/证书**
  - 生成 `/etc/sing-box/config.json`
  - 生成自签证书到 `/etc/sing-box/certs/`（HY2/TUIC 必需；VLESS 仅在未启用 Argo、以 WSS 对外时使用）
  - 若使用**受信任 CA 证书**（`--tls-cert-path` / `--tls-key-path`）并希望订阅链接里不写 `insecure`/`allowInsecure`，可加 `--tls-trusted`
- **systemd 管理**
  - 安装并启用 `/etc/systemd/system/sing-box.service`
  - 可选安装并启用 `/etc/systemd/system/cloudflared.service`（启用 `--argo` 时）
- **生成订阅文件**
  - 输出到 `/var/lib/sing-box/sub.txt`
  - 链接数量通常为：**启用协议数 × 用户数**
- **卸载（manifest 方案）**
  - 安装时写入 `/var/lib/sing-box/manifest.env`
  - 卸载时可按 manifest 精准清理（含二进制与 systemd unit）

## 安装/运行

脚本需要 root 权限（建议使用 `sudo`）。先看帮助，再按下方示例改参数即可。

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- --help
```

## 快速入门（小白一键三协议）

一条命令同时开 **VLESS / HY2 / TUIC**，并自动装依赖。`--host` 填公网 IP；能自动探测时可不写。

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --install-deps \
  --host "<YOUR_SERVER_PUBLIC_IP>" \
  --vless-port 8080 \
  --hy2-port 8443 \
  --tuic-port 9443
```

安装结束后终端会打印订阅内容，文件在 `/var/lib/sing-box/sub.txt`。需要多用户、SOCKS5 分流或 NAT 端口映射时，见下方「常用示例」。

## 常用示例

### 1) 启用 VLESS+WS（不启用 Argo，公网 WSS，自签证书）

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --vless-port 8080 \
  --user default
```

### 2) 启用 VLESS+WS + Cloudflare Tunnel（Quick Tunnel）

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --vless-port 8080 \
  --argo \
  --user default
```

### 3) 启用 VLESS+WS + Cloudflare Tunnel（Named Tunnel）

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --vless-port 8080 \
  --argo \
  --argo-domain "v.example.com" \
  --argo-token "<YOUR_TOKEN>" \
  --user default
```

### 4) 启用 HY2 + 2 个用户，其中一个用户走 SOCKS5

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --hy2-port 8443 \
  --user home \
  --user work \
  --user-socks5 work=127.0.0.1:1080
```

### 5) NAT VPS 端口映射

如果你的 VPS 是 NAT 共享 IP，服务商分配的公网端口与本机监听端口不同，可以用 `公网端口:监听端口` 的格式：

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --host "vpn.example.com" \
  --hy2-port 28443:8443 \
  --tuic-port 29443:9443 \
  --user default
```

上例中 sing-box 在本机监听 `8443`/`9443`，但订阅链接里的端口是 `28443`/`29443`（即客户端连接到公网映射端口）。如果公网端口与监听端口一致，直接写单值即可（如 `--hy2-port 8443`）。

### 6) 参数更全的参考模板：三协议 + 自动装依赖 + 多用户 + 多国家 SOCKS5

脚本的分流维度是 **用户名**（`auth_user`），不是“协议”。这意味着：

- 你给某个用户绑定了 SOCKS5，那么这个用户无论用 **VLESS/HY2/TUIC** 哪条入站进来，都会走同一个 SOCKS5 出站。
- 订阅链接数量通常是：**启用协议数 × 用户数**。例如 3 个协议 + 3 个用户，会生成 **9 条**链接；你只需要导入/使用其中你想用的那几条即可（链接名称里会带用户名与协议类型）。

`--user-socks5` 格式为 `用户名=地址:端口[:socks用户名[:socks密码]]`。下面示例用 **美国/台湾/日本** 三条 SOCKS5 来演示“落地到不同国家”的写法（请替换成你的真实 SOCKS5），并额外保留一个 `direct` 用户作为**不走代理**的默认用户。

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- \
  --install-deps \
  --vless-port 8080 \
  --hy2-port 8443 \
  --tuic-port 9443 \
  --user direct \
  --user us \
  --user tw \
  --user jp \
  --user-socks5 us=127.0.0.1:1081 \
  --user-socks5 tw=10.0.0.5:1080:tw-user \
  --user-socks5 jp=192.168.1.99:7890:jp-user:jp-pass
```

- **美国落地（无认证）**：`us=127.0.0.1:1081` → 仅 `主机:端口`。
- **台湾落地（仅用户名）**：`tw=10.0.0.5:1080:tw-user` → 只填 SOCKS 用户名（密码留空）。
- **日本落地（用户名+密码）**：`jp=192.168.1.99:7890:jp-user:jp-pass` → 用户名与密码都写齐。说明：这一行里 `:` 用来分段，**密码里不要包含 `:`**，否则解析可能错位/不完整。

如果你还希望让 VLESS 走 Cloudflare Tunnel（Argo），在上面的命令里加上（Quick Tunnel）：

```text
  --argo \
```

或（Named Tunnel）：

```text
  --argo \
  --argo-domain "v.example.com" \
  --argo-token "<YOUR_TOKEN>" \
```

## 输出文件与位置

- **sing-box 配置**：`/etc/sing-box/config.json`
- **自签证书**：`/etc/sing-box/certs/server.crt`、`/etc/sing-box/certs/server.key`
- **订阅文件**：`/var/lib/sing-box/sub.txt`
- **manifest**：`/var/lib/sing-box/manifest.env`
- **systemd units**：
  - ` /etc/systemd/system/sing-box.service `
  - ` /etc/systemd/system/cloudflared.service `（启用 `--argo` 时）

## 卸载

### 卸载（彻底清理）

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- uninstall
```

### 预览将要执行的操作

```bash
curl -fsSL "https://raw.githubusercontent.com/vevc/singbox-installer/main/install.sh" | sudo bash -s -- uninstall --dry-run
```

## 依赖

脚本会检查依赖命令；如缺失可加 `--install-deps` 让脚本自动安装（依赖发行版包管理器可用）。

## License

本项目以 [MIT License](LICENSE) 开源。

## 赞助

- 感谢 [TalorData](https://talordata.com/?campaignid=6200Bs8MUgqRU4D4&utm_source=YouTube&utm_term=vevcore) 提供赞助支持。