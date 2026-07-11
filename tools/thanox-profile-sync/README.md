# Thanox Profile Sync

这个目录沉淀“把本地情景模式 JSON 推到手机 Thanox 并启用”的流程。

## 文件

- `push-profile.sh`：主脚本。
- `helpers/thanox-profile-tool.jar`：调用 Thanox 导入、启用、publish 情景模式。
- `helpers/thanox-exec-action-dex.jar`：调用 Thanox 执行动作脚本，当前用于删除同名旧规则。

## 常用命令

```sh
tools/thanox-profile-sync/push-profile.sh \
  --adb-port 5038 \
  -s 192.168.50.187:35555 \
  files/profile/profiles/google_play_gms_guard.json
```

脚本会做这些事：

1. 读取 JSON 并在本地归一化成 Thanox 可导入的数组格式。
   - 支持仓库里的贡献格式：`{"profile": {...}}`。
   - 支持直接导入格式：`[{...}]`。
   - 支持多规则包装格式：`{"profiles": [{...}]}`。
2. 读取每条规则的 `name`。
3. 推送两个 helper jar 到 `/data/local/tmp/`。
4. 推送归一化后的 profile JSON 到 `/data/local/tmp/`。
5. 按 JSON 里的规则名删除手机里同名旧规则。
6. 调用 `ThanoxProfileTool add` 导入 JSON。
7. 调用 `ThanoxProfileTool enable` 启用导入的规则。

## 可选参数

```sh
DEVICE=192.168.50.187:35555 ADB_PORT=5038 \
  tools/thanox-profile-sync/push-profile.sh files/profile/profiles/google_play_gms_guard.json
```

- `--no-delete`：不删除同名旧规则。
- `--no-enable`：只导入，不自动启用。
- `--no-helper-push`：不重复推送 helper jar。
- `--dry-run`：只解析并打印规则名，不连接手机。
- `REMOTE_DIR=/data/local/tmp2`：改手机临时目录。

本地检查 JSON：

```sh
tools/thanox-profile-sync/push-profile.sh --dry-run \
  files/profile/profiles/google_play_gms_guard.json
```

## 关键点

- `adb push` 只是传文件，不会写入 Thanox。
- `ThanoxProfileTool add` 才会写入 Thanox 规则库。
- `ThanoxProfileTool enable` 才会启用规则。
- 覆盖更新时默认先按规则名删除旧规则，避免 Thanox 里残留同名旧动作。
