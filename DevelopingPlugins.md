# OpenSwift 插件开发指南（DevelopingPlugins）

OpenSwift 通过「插件」扩展能力：用 **一个目录 + `manifest.yml` + 脚本**即可实现如"启动某软件自动固定倍率"这类行为，无需修改主程序。插件分三层，可按需叠加：

| 层 | 载体 | 能力 |
| --- | --- | --- |
| **L1 声明层** | `manifest.yml` | UI 控件、目标软件匹配、脚本入口；零代码 |
| **L2 逻辑层** | `main.js`（JavaScriptCore） | 用宿主注入的 `openSwift.*` 桥 API 写行为逻辑（已实现） |
| **L3 原生扩展层** | `hooklib.dylib` | 深度注入 / 加速适配（预留，未实现） |

---

## 一、L1 声明层：manifest.yml 语法与支持格式

`manifest.yml` 是插件的必填清单。OpenSwift 用内置解析器加载它，支持 YAML（以及回退 JSON / plist）。

### 1.1 顶层字段

| 字段 | 必需 | 类型 | 说明 |
| --- | --- | --- | --- |
| `id` | 是 | string | 全局唯一标识，建议反向域名，如 `com.openswift.plugin.example` |
| `name` | 是 | string | 插件名称 |
| `version` | 是 | string | 插件版本，如 `1.0.0` |
| `min_app_version` | 否 | string | 所需最低 App 版本（当前校验未强制，建议填写） |
| `description` | 否 | string | 一句话描述 |
| `script` | 否 | string | L2 脚本相对路径（相对插件目录），如 `main.js`；缺省不加载脚本 |
| `hooklib` | 否 | string | L3 原生扩展相对路径（预留，当前不加载） |
| `ui` | 否 | array | UI 控件声明（见 1.2） |
| `targets` | 否 | array | 目标软件匹配声明（见 1.3） |

示例：

```yaml
id: com.openswift.plugin.example
name: 示例插件
version: 1.0.0
min_app_version: 0.1.0
description: 一句话描述
script: main.js
```

### 1.2 控件声明 `ui`

`ui` 是一个数组，每项定义一个控件。当前支持 **四种类型**：

| `type` | 控件 | 读写配置类型 | 说明 |
| --- | --- | --- | --- |
| `toggle` | 开关 | boolean | 开/关 |
| `button` | 按钮 | 无 | 点击触发脚本中同名函数 |
| `text` | 单行输入框 | string | 任意文本；**空串合法**（常用于表示"对所有有效"） |
| `number` | 数值输入框 | number(double) | 数值；非法输入会被忽略 |

每个控件支持的字段：

| 字段 | 必需 | 类型 | 说明 |
| --- | --- | --- | --- |
| `type` | 是 | string | 见上表 |
| `key` | 是 | string | 控件唯一键，也是脚本里 `openSwift.getConfig(key)` 读取的键 |
| `label` | 否 | string | 控件显示文案；缺省显示 `key` |
| `default` | 否 | 见类型 | 默认值。toggle→布尔；text→字符串；number→数值；button 无 |

配置值类型（`default` 与 `getConfig` 返回值支持的）：`string`、`bool`、`integer`、`number(double)`。

示例（目标 + 倍率 + 开关）：

```yaml
ui:
  - type: toggle
    key: enable_auto_speed
    label: 启用自动固定速度
    default: true
  - type: text
    key: target_process
    label: 目标进程（留空对所有有效）
    default: ""
  - type: number
    key: speed_ratio
    label: 加速倍率
    default: 3.0
  - type: button
    key: boost_now
    label: 立即加速
```

> 未知 `type` 会被安全忽略（渲染为空），不会导致插件加载失败。

### 1.3 目标匹配 `targets`

`targets` 是一个数组，每项描述一个待匹配的目标应用。当前用于元信息记录，运行时可配合 L2 脚本在 `onProcessLaunch` 里按 `appName` 自行判断（不强制）。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `bundle_id` | string | 目标应用的 Bundle Identifier |
| `process` | string | 目标进程名 |
| `ui_skip` | bool | 提示是否跳过 UI 进程（如 Renderer/GPU），免注入 |
| `speed_hook` | bool | 提示加速挂钩方式 |
| `children` | array | 需注入的关键子进程列表（元素同为 target 结构） |

示例：

```yaml
targets:
  - bundle_id: com.openswift.timertest
    process: TimerTestApp
    children:
      - process: helper_stub
```

---

## 二、L2 逻辑层：main.js 与 openSwift.* 脚本 API

`script` 指定的脚本（默认建议 `main.js`）由宿主用 **JavaScriptCore** 执行。脚本能使用完整 JavaScript 语法（变量、循环、字符串、条件等），并通过宿主注入的全局对象 **`openSwift`** 调用宿主能力。

开启方式：插件「已启用」且 `manifest.script` 非空时，App 启动/启用时加载执行；`setup()` 时会对当前已存在的进程补分发起始事件。

### 2.1 `openSwift` 方法总览

| 方法 | 签名 | 返回 | 说明 |
| --- | --- | --- | --- |
| `log` | `log(msg: string)` | — | 打印调试日志（OSLog），便于排查 |
| `onProcessLaunch` | `onProcessLaunch(callback)` | — | 注册回调，检测到新进程启动时调用 |
| `setSpeed` | `setSpeed(pid: number, ratio: number)` | — | 把指定进程设为倍率，并 **自动启用**速度控制（`is_active` 一并激活） |
| `getConfig` | `getConfig(key: string)` | `boolean \| string \| number \| undefined` | 读取插件 UI 控件的当前值（L1 ↔ L2 联动） |

### 2.2 回调参数 `info`（onProcessLaunch）

`onProcessLaunch` 的回调收到一个对象：

```js
openSwift.onProcessLaunch(function (info) {
    // info = {
    //   pid:     1234,        // 进程 pid（number）
    //   appName: "TimerTestApp", // 应用名（string）
    //   appURL:  "file:///.../TimerTestApp.app" // 应用路径（string）
    // }
});
```

同一个运行中的 App 实例里，同一进程（按 pid）只会触发一次回调。

### 2.3 方法详解

**`openSwift.log(msg)`** — 打印日志（可用于排查脚本是否执行、走到哪一步）：

```js
openSwift.log("startup_fixed_speed loaded");
```

**`openSwift.onProcessLaunch(callback)`** — 注册进程启动回调：

```js
openSwift.onProcessLaunch(function (info) {
    openSwift.log("launched " + info.appName + " pid=" + info.pid);
});
```

**`openSwift.setSpeed(pid, ratio)`** — 设速。`ratio` 为倍率（如 `3.0` 表示 3 倍速，`0.5` 表示半速）。该调用会**自动启用**该进程的速度控制（等价于"设倍率 + 打开开关"）：

```js
openSwift.setSpeed(1234, 3.0);
```

**`openSwift.getConfig(key)`** — 读取 UI 控件当前值（持久化，重启后保持）：

```js
var enabled = openSwift.getConfig("enable_auto_speed"); // true/false/undefined
var ratio = Number(openSwift.getConfig("speed_ratio")); // 3.0
```

---

## 三、完整示例

一个「目标或所有软件启动时自动设固定倍率」的插件：

`manifest.yml`：

```yaml
id: com.openswift.plugin.startup_fixed_speed
name: 启动自动固定速度
version: 1.0.0
description: 目标或所有软件启动时自动设为固定倍率
script: main.js

ui:
  - type: toggle
    key: enable_auto_speed
    label: 启用自动固定速度
    default: true
  - type: text
    key: target_process
    label: 目标进程（留空对所有有效）
    default: ""
  - type: number
    key: speed_ratio
    label: 加速倍率
    default: 3.0

targets:
  - process: TimerTestApp
```

`main.js`：

```js
// 启动自动固定速度插件（L2 脚本）
openSwift.log("startup_fixed_speed loaded");

openSwift.onProcessLaunch(function (info) {
    openSwift.log("process launched: " + info.appName + " pid=" + info.pid);

    if (openSwift.getConfig("enable_auto_speed") === false) {
        return; // L1 开关已关闭，不自动设速
    }

    var target = openSwift.getConfig("target_process");
    if (target && target.length > 0) {
        if (!info.appName || info.appName.indexOf(target) < 0) {
            return; // 指定了目标但当前进程不匹配
        }
    }

    var ratio = Number(openSwift.getConfig("speed_ratio"));
    if (!ratio || ratio <= 0) {
        ratio = 3.0; // 未配置则回退默认 3.0
    }

    openSwift.setSpeed(info.pid, ratio);
    openSwift.log("auto set " + ratio + "x for pid=" + info.pid);
});
```

---

## 四、分发与安装

插件以 **zip** 分发，zip **顶层必须是插件目录**（内含 `manifest.yml`）。

```bash
cd plugin/test
rm -f startup_fixed_speed.zip
zip -r startup_fixed_speed.zip startup_fixed_speed
```

安装方式：
1. **本地导入**：OpenSwift「插件」面板 →「导入插件」选择 zip。
2. **在线下载**：OpenSwift「插件」面板 →「在线插件」区 → 刷新 → 下载（从 GitHub Release `plugin` 拉取清单 `plugin_index.json`，见下）。

在线分发需要发布一个 `plugin` Release，附带：

`plugin_index.json`（App 读取的在线清单，UTF-8）：

```json
[
  {
    "id": "com.openswift.plugin.startup_fixed_speed",
    "name": "启动自动固定速度",
    "version": "1.0.0",
    "description": "目标或所有软件启动时自动设为固定倍率",
    "asset": "startup_fixed_speed.zip"
  }
]
```

| `plugin_index.json` 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 插件唯一 id（与 manifest 一致） |
| `name` | string | 显示名称 |
| `version` | string | 版本 |
| `description` | string | 描述 |
| `asset` | string | 对应 **Release 附件中 zip 的文件名** |

发布命令：

```bash
gh release create plugin --title "Plugins" --notes "OpenSwift 插件源" --target main \
  plugin/test/startup_fixed_speed.zip plugin/test/plugin_index.json
# Release 已存在时更新附件：
gh release upload plugin plugin/test/startup_fixed_speed.zip plugin/test/plugin_index.json
```

---

## 五、L3 原生扩展（预留）

`hooklib.dylib` 为预留能力：开发者自行研究与实现底层注入/加速逻辑，App 仅按约定加载。当前版本不加载 hooklib，也无需在 manifest 中填写。后续版本开放。

---

## 六、参考实现

仓库内已有的可运行示例插件（含 L1 + L2）：

- `plugin/test/startup_fixed_speed/`：目标或所有软件启动时自动设固定倍率
- 其线上清单位于 Release `plugin` 的 `plugin_index.json`

可直接复制该目录结构作为新插件起点。