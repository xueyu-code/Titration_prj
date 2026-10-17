# 滴定仪 BLE 通信协议 v1

App 与 ESP32-S3 固件之间的唯一约定。改协议先改本文档，再改两端代码。

## 1. GATT 结构

| 项 | UUID | 属性 | 方向 |
|---|---|---|---|
| Service | `f65c0001-8221-4068-aa47-28e41eec47fd` | — | — |
| CMD 特征 | `f65c0002-8221-4068-aa47-28e41eec47fd` | Write（带响应） | App → 设备 |
| EVT 特征 | `f65c0003-8221-4068-aa47-28e41eec47fd` | Notify | 设备 → App |

- 广播包或扫描响应里应包含 Service UUID 和设备名（建议 `Titrator-XXXX`），App 用它把滴定仪排在扫描列表最前。
- 连接后 App 请求 MTU 247，单条消息不得超过 `MTU - 3` 字节（244）。
- App 订阅 EVT 后，设备应立即推送一次 `state`。

## 2. 消息格式

每次写入 / 每条通知是**一个** UTF-8 JSON 对象，不分包、不加换行。
数值用 JSON number；pH 保留 2 位小数即可。未知字段应忽略，未知 `cmd` / `evt` 应忽略（设备可回 `error`）。

### 2.1 命令（App → 设备，写 CMD）

| `cmd` | 其他字段 | 说明 |
|---|---|---|
| `titrate` | `target`: 目标 pH（0–14，2 位小数） | 开始自动滴定。设备根据当前 pH 与目标值控制两路注射器加液：pH 高于目标加酸（通道 1），低于目标加碱（通道 2），接近目标时应减小单次加液量 |
| `stop` | — | 立即停止所有电机和滴定，回到 `idle` |
| `move` | `ch`: 1 / 2，`dir`: `"in"` / `"out"` | 单步动作：`in` 吸液（电机反转），`out` 排液（电机正转），步长由固件定 |
| `jog` | 同 `move` | 持续动作。App 在按住按钮期间每 300 ms 重发一次；设备超过 1000 ms 未收到新的 `jog` 必须自动停止 |
| `cal_start` | — | 进入标定模式，清空本次标定的临时数据 |
| `cal_point` | `ph`: 当前缓冲液的标准 pH | 采样直到读数稳定，记录该标定点，完成后回 `cal_point` 事件 |
| `cal_finish` | — | 用已记录的点计算斜率 / 零点并保存，回 `cal_done` 事件，回到 `idle` |
| `cal_abort` | — | 放弃本次标定，保留旧的标定参数，回到 `idle` |

示例：`{"cmd":"titrate","target":7.00}`、`{"cmd":"jog","ch":1,"dir":"in"}`

### 2.2 事件（设备 → App，EVT 通知）

| `evt` | 字段 | 说明 |
|---|---|---|
| `ph` | `v`: 当前 pH | 周期上报，建议 2 Hz（不低于 1 Hz）。设备没有实时时钟，时间戳由 App 在收到时打 |
| `state` | `s`: `idle` / `titrating` / `moving` / `calibrating` | 状态变化时上报，订阅后立即上报一次 |
| `cal_point` | `ph`: 标准值，`ok`: bool，可选 `mv`: 电极电压 | 一个标定点的结果，`ok=false` 表示读数不稳定或超范围 |
| `cal_done` | `ok`: bool，可选 `slope`: 斜率（%），`offset`: 零点偏移（mV） | 标定结果 |
| `error` | `code`: 错误码，可选 `msg`: 说明 | 见下表 |

示例：`{"evt":"ph","v":6.98}`、`{"evt":"state","s":"titrating"}`

### 2.3 错误码

| `code` | 含义 |
|---|---|
| `busy` | 当前状态不允许该命令（如滴定中收到 `move`） |
| `limit` | 注射器到达行程极限 |
| `sensor` | pH 电极异常 |
| `bad_cmd` | 无法解析或参数非法 |

## 3. 行为约定

- **断开即停**：BLE 连接断开时，设备必须立即停止所有电机（滴定也停止）。
- **滴定完成由 App 判定**：滴定中 App 连续 5 s 读到 `|pH - target| ≤ 0.05` 即判定完成，发送 `stop` 并提醒用户。设备自行停止（如到达极限）时先发 `error` 再发 `state: idle`。
- 状态与命令：`idle` 下接受全部命令；`titrating` 下只接受 `stop`；`moving` 下接受 `move` / `jog` / `stop`；`calibrating` 下只接受 `cal_*` 和 `stop`（`stop` 等同 `cal_abort`）。其余情况回 `error: busy`。
- 标定点顺序由 App 引导：先中性缓冲液（6.86 或 7.00），再酸性（4.00 / 4.01），可选碱性（9.18 / 10.01）。至少 1 个点才能 `cal_finish`（1 点只校零点，2 点及以上同时校斜率）。
