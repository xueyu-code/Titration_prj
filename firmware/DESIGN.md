# 滴定仪固件设计

版本 0.1，对应协议 v3（`docs/protocol.md`）。协议是 App 和固件之间唯一的契约，本文与协议冲突时以协议为准，并且应先修改协议。

标记说明：**[待确认]** 表示取决于还没到手的硬件或还没确认的接线；**[待实测]** 表示要在联调时测量后再定。完整清单见第 18 节。

---

## 0. 结论速览

| 问题 | 决定 | 理由（详见对应章节） |
|---|---|---|
| STEP 脉冲 | **MCPWM 产生脉冲 + PCNT 计数**，每个周期开头由中断决定下一个周期的长度或停止 | 脉冲由硬件产生，PCNT 计的是引脚上真实发出的脉冲数，步数精确；停止只需写寄存器，可以在 ISR 里立即生效；两路之间不共享任何硬件（第 4 节） |
| pH ADC | **ESP32-S3 内部 ADC1**，6 dB 衰减，DMA 连续采样 10 kSPS，每 500 ms 窗口平均 5000 个点 | 按数据手册数字估算，噪声和分辨率都有 3 倍以上余量；唯一风险是积分非线性，需要实测确认（第 1.3 节）。不实现外置 ADC |
| PH-4502C | 5 V 供电，Po 经 15 kΩ/10 kΩ 分压接 GPIO1；To、Do 不接 | 3.3 V 供电时 LM358 输出上不到 2.5 V 偏置点；5 V 供电时 Po 最高约 3.5 V，必须分压（第 1.2 节） |
| TMC2209 | **STEP/DIR 独立模式**：MS1=MS2=VIO（1/16 微步），PDN、CLK 接 GND，USART 悬空，两路共用一根 EN | UART 带来的电流软件设置、StallGuard 等对本项目没有实际收益（第 1.4 节） |
| 纯逻辑 | 放在 `components/core`，不依赖 ESP-IDF，用 gcc + CMake + Unity 在主机上测，包括"带模拟烧杯的闭环" | 没有硬件也能验证（第 14 节） |
| 任务模型 | 只有一个控制任务调用 `device_*`；BLE、采样、电机中断都只往一个队列里发消息 | 业务状态只有一个所有者，不需要锁（第 3 节） |

已验证：所有主机测试通过（含带模拟烧杯的闭环）；ESP-IDF v5.5.5 用 N16R8 配置执行 `idf.py build` 通过、无警告（esp32s3，镜像 556 KiB，1.5 MB 分区还剩 63%）。还没有在硬件上验证任何东西，待验证项见第 19 节。

---

## 1. 硬件决策

### 1.1 板卡和模组

ESP32-S3-DevKitC-1（v1.0 或 v1.1），模组 ESP32-S3-WROOM-1-N16R8（丝印和板卡版本见第 18 节）。与固件有关的事实：

| 项 | 事实 | 对固件的影响 |
|---|---|---|
| Flash / PSRAM | 16 MB 四线（quad）SPI Flash + 8 MB 八线（octal）SPI PSRAM（封装内，ESP32-S3R8），VDD_SPI 均为 3.3 V | `sdkconfig.defaults` 打开 `ESPTOOLPY_FLASHMODE_QIO`、`ESPTOOLPY_FLASHSIZE_16MB`、`SPIRAM_MODE_OCT`；四线 Flash 没有 eFuse 要求 |
| 被占用的 GPIO | GPIO26–32 用于 Flash/PSRAM 的 SPI 总线，排针上不引出；GPIO33–37 被八线 PSRAM 占用，排针上虽然有 35/36/37，但不可用 | 全部避开 |
| GPIO47/48 | WROOM-1 上是普通的 **3.3 V** GPIO | 48 因 v1.0 的 RGB LED 而避开；47 留作备用 |
| Strapping | GPIO0（弱上拉）、GPIO3（悬空）、GPIO45、GPIO46（弱下拉） | 避开 |
| USB | GPIO19 = D−，GPIO20 = D+（原生 USB / USB-Serial-JTAG） | 避开 |
| UART0 | GPIO43 TX、GPIO44 RX，接板载 USB 转串口，用作控制台 | 避开 |
| RGB LED | v1.1 在 **GPIO38**，v1.0 在 **GPIO48**；板卡版本尚未确认 | 38 和 48 都不使用，保留 |
| JTAG | GPIO39–42 是 MTCK/MTDO/MTDI/MTMS；默认 JTAG 走 USB，这几个脚可以当普通 GPIO 用 | 留作备用 |
| Flash 速度 | Flash QIO 80 MHz + 八线 PSRAM 80 MHz 是支持的组合 | 两者都用 80 MHz |

### 1.2 pH 前端：PH-4502C

引脚：To（温度输出）、Do（比较器阈值输出）、**Po（pH 模拟输出）**、G（信号地）、G（电源地）、U+（电源）。两个电位器：参考调整（偏置）和阈值调整（只影响 Do）。

| 项 | 结论 |
|---|---|
| 供电 | **U+ 接 5 V**（DevKitC 的 5V 脚）。两个 G 都接 ESP32 GND，信号地和 Po 线绞在一起走 |
| 增益和极性 | 社区常用公式是 `pH = 7 + (2.5 − Po) / 0.18`，即 pH 7 时 Po ≈ 2.5 V，pH 每升 1，Po 降约 0.18 V。电极的斜率是 −59.16 mV/pH，所以 Po ≈ 2.5 V + **3.0 × E_电极**：同相，增益约 +3 **[待实测]**。用两个已知电压实测时，如果发现是反相，把 `FE_MODULE_GAIN` 设为负数即可，公式不用改 |
| Po 范围（5 V） | 按公式，pH 0–14 对应 Po 3.74–1.26 V；pH 4–10 对应 3.03–1.97 V。LM358 单电源 5 V 供电时，输出上限约 3.5 V（V+ − 1.5 V），因此 **pH 低于约 1.6 时 Po 饱和**，这是模块本身的测量上限 **[待实测]** |
| 是否分压（5 V） | **必须分压**：3.5 V 以上会超过 ESP32-S3 引脚的绝对最大值（VDD + 0.3 V = 3.6 V），也超出 ADC 的有效量程。用 **15 kΩ（上）/ 10 kΩ（下），分压比 0.4**，ADC 脚再接 100 nF 到地（数据手册的 ADC 指标就是在 100 nF 条件下测的，它同时是 265 Hz 的抗混叠低通）。分压后 Po 1.26–3.5 V 对应 ADC 0.50–1.40 V，落在 6 dB 衰减的有效量程 0–1600 mV 以内。即使 Po 意外到 5 V，ADC 脚也只有 2.0 V，是安全的 |
| 3.3 V 供电 | **不推荐**。LM358 输出上限只有约 1.8 V，达不到 2.5 V 的偏置点；把偏置调到 0.9 V 左右虽然勉强能用，但量程只剩约 ±300 mV（约 pH 2–12），而且模块是按 5 V 设计的。如果一定要用 3.3 V 供电，可以不分压，改用 12 dB 衰减，但需要整体重新实测 |
| 偏置调整 | BNC 短接（电极端 0 mV）时，用参考电位器把 Po 调到 2.50 V，此时 ADC 读数约 1000 mV，在 6 dB 量程的中间。然后在串口日志里读出实测值，写入 `FE_BIAS_MV`。调过电位器以后，要重测并在 App 里重新标定（协议 2.4） |
| To / Do | **不接**。To 测的是电路板上的温度，不是溶液温度，而且协议约定不做温度补偿；Do 只是一个比较器开关量，对本项目没有用。同意不使用 |
| 探头 | 不需要关心型号：标定在 App 里完成，整条链路（电极、模块、分压、ADC）的增益和零点都会被标定吸收 |

`config.h` 中相应的默认值：`FE_MODULE_GAIN = 3.0`、`FE_DIVIDER = 0.4`、`FE_GAIN = 1.2`、`FE_BIAS_MV = 1000`。

### 1.3 ADC：内部 ADC1 能否满足需求

**结论：按数据手册的数字估算可以满足，所以选用内部 ADC1，不实现外置 ADC。** 唯一需要在联调时实测确认的是积分非线性（INL）。

信号链：1 mV（电极端）× 3.0（模块）× 0.4（分压）= **1.2 mV（ADC 端）**。

ESP32-S3 数据手册 5.5 节的数字（测量条件：ADC 脚接 100 nF，直流输入，25 °C）：DNL ±4 LSB，INL ±8 LSB，采样率最高 100 kSPS；校准后总误差：ATTEN2（6 dB，有效量程 0–1600 mV）±10 mV，ATTEN3（12 dB，0–2900 mV）±50 mV。

| 指标 | 要求 | 内部 ADC1（6 dB，12 位，1 LSB ≈ 0.4 mV） | 判断 |
|---|---|---|---|
| 单个 LSB | — | 0.4 mV ÷ 1.2 ≈ **0.33 mV 电极端 ≈ 0.006 pH** | — |
| 读数噪声（每 500 ms 一个读数） | App 判稳：10 个读数的 `mv` 极差 ≤ 1.0 mV。正态分布下 10 个样本的极差约为 3σ，所以需要 σ ≲ 0.3 mV（电极端） | 数据手册没有给出原始噪声。按 σ = 2–5 LSB 估算 **[待实测]**；一个窗口有 5000 个采样，白噪声下 σ 降为 1/70；即使只有 1/10 的采样相互独立，也降为 1/22，即 0.1–0.23 LSB ≈ **0.03–0.08 mV**（电极端） | 余量 ≥ 3 倍 |
| 分辨率 | 上报保留 2 位小数（0.01 pH ≈ 0.6 mV） | 先对原始码求平均，再按校准曲线插值，分辨率远小于 1 LSB | 满足 |
| 固件判稳 | 8 个读数极差 ≤ 0.03 pH ≈ 1.8 mV | 同上 | 满足 |
| 完成带 | ±0.05 pH ≈ ±3 mV | 同上 | 满足 |
| DNL ±4 LSB | — | 原始噪声起抖动作用，5000 点平均后被平滑（数据手册脚注也这样建议） | 满足 |
| 增益和零点误差（±10 mV 量级） | — | App 对整条链路做两点或三点标定，会把它吸收掉 | 不构成问题 |
| **INL ±8 LSB** | 标定点之间的准确度 | 这是全量程的最坏值：±3.2 mV（ADC 端）≈ ±2.7 mV（电极端）≈ **±0.045 pH**。实际工作窗口（pH 4–10 对应 ADC 0.79–1.21 V，只占约 1000 LSB）里的偏差应远小于这个值；IDF 的曲线拟合校准和 App 的三点拟合还会再吸收一部分 | **风险项 [待实测]** |
| 工频干扰 | — | 窗口正好 500 ms，覆盖整 25 个 50 Hz 周期和整 30 个 60 Hz 周期，平均后基本抵消 | 满足 |
| 与 BLE 共存 | — | 只用 ADC1；ADC2 才和 Wi-Fi 冲突 | 满足 |

**联调时的验收测量**（清单见第 19 节）：用电位器分压出 0.7–1.3 V 之间的约 10 个电压点，用万用表读出实际值，与固件日志里的 `V_adc` 对照，做直线拟合。残差 ≤ 1.2 mV（ADC 端，相当于 1 mV 电极端、约 0.017 pH）即合格。如果不合格，就把 `ph_adc.c` 换成外置 ADS1115（16 位，INL ±1 LSB），走 I2C，接口 `ph_adc.h` 不变，其他代码都不用改；GPIO8/GPIO9 可以留作 I2C 引脚。

**实现要点**（`ph_adc.c`）：用 `adc_continuous` 驱动，单通道 ADC1_CH0，6 dB 衰减，12 位，`BOARD_PH_ADC_SAMPLE_HZ` = 10 kHz，DMA 帧取约 100 ms（1000 个采样 × 4 B）。每累计 5000 个采样（按采样个数而不是按墙上时间分窗，这样工频抵消是精确的），就把原始码之和除以个数得到浮点均值，再用初始化时建好的分段线性表转换成 mV。这张表在 0–4095 之间每隔 64 个码取一个节点，节点值由 `adc_cali_raw_to_voltage`（曲线拟合方案）给出。之所以不直接对均值调用 `adc_cali_raw_to_voltage`，是因为它只接受整数码、输出整数 mV，会产生 1 mV 的台阶（相当于 0.83 mV 电极端），这比判稳要求的 1 mV 极差小不了多少。

没有 pH 模块时，可以用 10 kΩ（接 3V3）和 4.7 kΩ（接 GND）分出约 1.05 V，接到 GPIO1 上代替模块，读数约 pH 6.2，可以用来联调 App。所以不需要再写一个假 ADC。

### 1.4 步进驱动：TMC2209（StepStick 模块）

模块引脚：左排 EN、MS1、MS2、PDN、USART、CLK、STEP、DIR；右排 VM、GND、M1B、M1A、M2A、M2B、VIO、GND。

**模式：STEP/DIR 独立模式，不接 UART。** UART 能带来的东西：软件设置电流（可以用 VREF 电位器代替）、诊断寄存器（实验室设备用不到）、StallGuard 无传感器回零（不建议，见第 17 节）、256 微步（独立模式下芯片本来就会内插到 256 微步）。这些都没有明确收益，反而要多一个 UART 外设、单线半双工、CRC 和上电寄存器初始化。

| 模块脚 | 通道 1（酸） | 通道 2（碱） | 说明 |
|---|---|---|---|
| EN | **GPIO15**（两路共用） | 同左 | 低电平有效（ENN），低 = 驱动使能。外加 10 kΩ 上拉到 3.3 V，保证 ESP32 复位期间驱动处于关闭状态 **[待确认：模块板上 EN 是否已有上拉或下拉]** |
| MS1 / MS2 | **接 VIO / 接 VIO** | 同左 | 硬件固定 **1/16** 微步，不占 GPIO。芯片内部有下拉，悬空时是 1/8，所以必须接高 |
| PDN | **接 GND** | 同左 | 独立模式下，低电平启用静止时自动降电流（TMC2209 数据手册 PDN_UART 引脚说明）。因为驱动一直保持使能，这一点可以防止电机在静止时发热 **[待确认：对照模块原理图]** |
| USART | **悬空** | 同左 | 它通过模块上的 1 kΩ 电阻接到 PDN_UART，不用 UART 时不接 |
| CLK | **接 GND** | 同左 | 使用内部 12 MHz 时钟（数据手册："Tie to GND using short wire for internal clock"）。如果模块板上已经接地，悬空也可以 |
| STEP | **GPIO4** | **GPIO6** | MCPWM 输出 |
| DIR | **GPIO5** | **GPIO7** | 哪个电平代表"排液"由 `BOARD_DIR_OUT_LEVEL` 按通道设定 **[待确认：取决于电机接线]** |
| VIO | 3.3 V | 3.3 V | 来自 DevKitC 的 3V3 |
| VM / GND | 12–24 V 电机电源 | 同左 | **[待确认]** 电压。VM 脚旁边加 ≥ 100 µF 电解电容；电机电源和 ESP32 共地 |
| M1A/M1B/M2A/M2B | 电机两相 | 同左 | **通电时不要插拔电机线**，否则会损坏驱动 |
| VREF 电位器 | — | — | 按模块说明调电流。注射器负载很小，建议先从电机额定电流的 50–70 % 开始 **[待确认：电机型号和额定电流]** |

**EN 策略**：`stepper_init()` 配好 STEP/DIR 以后把 EN 拉低，之后一直保持使能，静止时由 TMC2209 自动降低电流。这样就不需要每次运动前后开关驱动，也不会因为断电让转子落到整步位置而丢掉微步位置；同时省掉一个 GPIO。

**时序要求**（TMC2209 数据手册）：STEP 高、低电平各至少约 100 ns（tCLK + 20 ns）；DIR 相对 STEP 上升沿的建立和保持时间至少 20 ns；最高步进频率是 fCLK/2。本设计的余量：脉冲占空比 50 %，最高 1212 步/秒时高电平也有 412 µs；DIR 只在电机停止时改变，第一个上升沿在启动后半个周期（≥ 0.4 ms）才出现。

**微步：1/16（MS1=H，MS2=H）**。TMC2209 在独立模式下会把每个输入步内插成 256 微步，所以选择哪一档只影响两件事：每步对应的体积，以及需要的脉冲频率。运行平稳度和噪声与档位无关。按默认机械参数（T8 丝杆导程 8 mm、10 mL 注射器约 165 µL/mm，均 **[待确认]**）：

| 档位 | µL/步 | 最小剂量 5 µL 对应步数（量化误差） | 0.5 mL/s 所需频率 |
|---|---|---|---|
| 1/8 | 0.83 | 6 步（±7 %） | 606 Hz |
| **1/16** | **0.41** | **12 步（±3.4 %）** | **1212 Hz** |
| 1/32 | 0.21 | 24 步 | 2424 Hz |
| 1/64 | 0.10 | 48 步 | 4848 Hz |

42 步进电机的微步位置精度本来就只有整步的几分之一（整步 = 16 微步 ≈ 6.6 µL），1/16 以上的档位只是提高了名义分辨率，实际精度并不会更好。1/16 下最小剂量的量化误差约 0.2 µL，相当于缓冲样品上不到 0.001 pH，远小于 `HOLD_TOL` 的 0.02，脉冲频率也低。如果实际导程是 2 mm，1/16 档下每步 0.10 µL，0.5 mL/s 需要 4850 Hz，仍然在设计能力之内（第 4 节）。

### 1.5 限位开关

每个通道只在排空端有一个开关。**建议使用常闭（NC）触点接 GND**，配内部上拉，外加 10 kΩ 上拉和 100 nF 对地电容。开关断开（到达端点）时为高电平，有效电平 `BOARD_LIMIT_ACTIVE_LEVEL = 1`。这样断线时读到的也是"已到端点"，设备会拒绝排液而不是一直顶下去，属于失效安全。如果用的是常开触点，把有效电平改成 0 即可。光电开关如果是 5 V 输出，需要分压 **[待确认：开关类型]**。

---

## 2. 总体架构

### 2.1 目录结构

```
firmware/
├── CMakeLists.txt            ESP-IDF 工程（MINIMAL_BUILD）
├── sdkconfig.defaults        四线 Flash + 八线 PSRAM、NimBLE、IRAM、日志
├── version.txt               固件版本 → esp_app_desc
├── DESIGN.md                 本文
├── main/
│   └── main.c                装配：队列、任务、device 的端口实现
├── components/
│   ├── core/                 纯 C，不依赖 ESP-IDF（主机上同样能编译）
│   │   ├── include/core/
│   │   │   ├── types.h         通道、方向、状态、错误码、标定参数
│   │   │   ├── config.h        全部常量（第 12 节）
│   │   │   ├── clog.h          日志宏：目标上是 ESP_LOGx，主机上是 stderr
│   │   │   ├── protocol.h      命令解析（cJSON）、事件编码（snprintf）
│   │   │   ├── ph.h            电压 → mV → pH 换算
│   │   │   ├── sensor_fault.h  电极异常判定
│   │   │   ├── axis.h          单轴：位置、归位、软限位、回差、速度曲线
│   │   │   ├── titration.h     滴定控制环
│   │   │   └── device.h        状态机和协议行为（对应模拟器 SimTitrator）
│   │   ├── src/*.c
│   │   └── linker.lf           axis.c 放进 IRAM（每步一次的中断会调用它）
│   └── platform/             ESP-IDF 薄层，不含业务逻辑
│       ├── include/platform/
│       │   ├── board.h         引脚和接线常量
│       │   ├── stepper.h       MCPWM + PCNT 两路步进
│       │   ├── ph_adc.h        ADC1 连续采样，窗口平均
│       │   ├── ble_link.h      NimBLE GATT 服务
│       │   └── cal_store.h     NVS 中的标定参数
│       └── src/*.c
└── test/host/                主机测试（gcc + CMake + Unity）
    ├── CMakeLists.txt
    ├── test_*.c
    └── sim/                  烧杯模型和闭环测试台
```

### 2.2 依赖方向

```
main ──► platform ──► core
  └──────────────────►  core
core ──► (只依赖 cJSON；clog.h 在 ESP_PLATFORM 下依赖 esp_log)
test/host ──► core + sim
```

- `core` 不包含任何 ESP-IDF 头文件。它通过 `device_ports_t`（发事件、启停电机、保存标定）这组函数指针与外界交互，所以在主机上可以接假实现来测试。
- `platform` 可以使用 `core` 的类型（`axis_t`、`cal_t`），但不包含任何业务规则：它不知道什么是滴定，也不知道协议的状态表。
- `main.c` 只负责装配，不做判断。

### 2.3 模块职责

| 模块 | 层 | 职责 | 运行上下文 |
|---|---|---|---|
| `protocol` | core | JSON → `cmd_t`（含协议规定的取值范围）；`evt_t` → JSON | 控制任务 |
| `ph` | core | 协议 2.4 的换算；标定参数范围 | 控制任务 |
| `sensor_fault` | core | 读数贴近量程两端持续 2 s，进入异常时只报一次 | 控制任务 |
| `axis` | core | 位置、归位、软限位、回差，梯形速度曲线（只用整数运算） | MCPWM ISR + 控制任务（临界区保护） |
| `titration` | core | 协议第 4 节的控制环 | 控制任务 |
| `device` | core | 协议第 3 节：状态机、命令、jog 看门狗、编排滴定、事件顺序 | 控制任务 |
| `stepper` | platform | MCPWM/PCNT/GPIO，每个周期调用 `axis_next()`，结束时回调 | ISR + 控制任务 |
| `ph_adc` | platform | ADC 连续采样，窗口平均，曲线校准 | 采样任务 |
| `ble_link` | platform | NimBLE 初始化、GATT、广播、通知 | NimBLE host 任务 + 控制任务（通知） |
| `cal_store` | platform | NVS 读写标定参数 | app_main + 控制任务 |
| `main` | app | 队列、任务、端口实现 | — |

---

## 3. 任务和线程模型

| 上下文 | 核 | 优先级 | 做什么 |
|---|---|---|---|
| BLE 控制器 | 0 | 系统 | — |
| NimBLE host 任务 | 0 | 21（IDF 默认值） | GATT 回调：把写入的字节拷进 `MSG_WRITE`；订阅时发 `MSG_SUBSCRIBE`；断开时发 `MSG_DISCONNECT` 并重新广播。只做 `xQueueSend(…, 0)`，不阻塞 |
| **控制任务 `ctl`** | **1** | 6 | **唯一调用 `device_*` 的地方**。阻塞在队列上，超时为 `CTL_TICK_MS` = 50 ms；每次醒来都调用一次 `device_tick()`。也在这个任务里调用 `stepper_init()`，所以 MCPWM 中断落在核 1 |
| 采样任务 `sensor` | 1 | 5 | 循环调用 `ph_adc_read()`（它阻塞到下一个 500 ms 窗口结束），然后发 `MSG_SAMPLE` |
| MCPWM 定时器 ISR | 1 | 低（1–3） | 每个步进周期开始时调用 `axis_next()`，设置下一个周期或停止；运动结束时调用 `main` 提供的回调，用 `xQueueSendFromISR` 发 `MSG_MOTION_END` |
| PCNT ISR | 1 | 低 | 只在计数溢出时由驱动内部累加，不涉及业务 |

**同步规则**

1. 业务状态（`device_t`，以及其中的 `titr_t`、`sensor_fault_t`）只由控制任务访问，不需要锁。
2. 所有输入（BLE、采样、电机结束）都进入**同一个队列**，因此天然有序：断开连接之前写入的命令，一定先于 `MSG_DISCONNECT` 被处理。
3. `axis_t` 由 MCPWM ISR 和控制任务共享，每个通道各有一个 `portMUX_TYPE`。`stepper_extend()` 和 `stepper_halt()` 在临界区里修改它；ISR 内用 `portENTER_CRITICAL_ISR`。两个通道之间不共享锁。
4. 过期的运动结束消息用 `tag` 过滤：每次 `motor_start` 都使用新的 tag，`device_on_motion_end` 忽略不匹配的 tag。例如设备已经因为新命令停掉了旧运动，但旧运动的 `DONE` 已经在队列里。
5. 通知：`ble_link_notify()` 只在控制任务里调用。连接句柄和订阅标志由 host 任务写、控制任务读，两者都是原子大小的变量；如果读到的是刚断开的连接，NimBLE 发送失败，事件被丢弃，这是可以接受的。

**队列消息**（`main.c` 中的 `ctl_msg_t`，约 110 B × 16 项）：`MSG_WRITE{len, data[101]}`、`MSG_SUBSCRIBE`、`MSG_DISCONNECT`、`MSG_SAMPLE{ok, v_adc_mv}`、`MSG_MOTION_END{ch, status, tag}`。队列预留 `CTL_QUEUE_RESERVE`（4）个空位给运动结束、订阅和断开这三种不能丢的消息：订阅和断开最多阻塞 100 ms 等待空位；ISR 的运动结束消息可以占用全部剩余空间，万一仍然发送失败就累加一个计数，由控制任务醒来时报 ERROR。只有 BLE 写入和采样两种消息，会在空位不多于预留数时被丢弃并记一条日志（正常情况下不会发生，App 每秒最多发几条）。不回 ATT 错误（协议第 1 节）。

**栈**：控制任务 6 KB（cJSON 解析，以及带浮点格式的 snprintf），采样任务 4 KB，NimBLE host 任务 4 KB（默认值）。

**延迟预算**：BLE 写入到执行小于 1 ms；断开到电机停止小于 1 ms；限位开关在下一个步进脉冲之前生效（第 4 节）；jog 超时在 1000–1050 ms 之间停止。

---

## 4. 步进脉冲方案

### 4.1 需求和选型

需求：(1) 步数精确，单步和定量加液都要；(2) 两路互不干扰；(3) 支持持续运动（jog）和中途停止；(4) 限位开关触发后立即停。约束：用芯片自带的脉冲外设产生 STEP，不用 GPIO 翻转模拟。

| 方案 | 步数精确 | 中途停止后知道走了多少步 | 限位立即停 | 运行中延长目标（`move` 累加） | 结论 |
|---|---|---|---|---|---|
| RMT + 自定义编码器（IDF `examples/peripherals/rmt/stepper_motor`，或 `rmt_new_simple_encoder` 逐步生成） | 正常结束时精确 | **不知道**：`rmt_disable()` 中止时，硬件缓冲（S3 每个通道 48 个符号）里有多少已经发出去是未知的，必须另加 PCNT | `rmt_disable()` 不能在 ISR 里调用（内部使用非 ISR 临界区、队列和日志），只能在 ISR 里唤醒高优先级任务后再停，否则要等缓冲里最多 48 步发完 | 编码器读一个共享变量即可 | 可行，但"立即停"和"中止后精确计数"都要绕路 |
| **MCPWM + PCNT** | PCNT 计的是引脚上真实的上升沿 | 停止后读 PCNT 即可 | 停止就是强制输出低电平（`gen_cntuforce_upmethod = 0`，立即生效）加上停定时器，都是寄存器写，ISR 中可以直接做 | 修改 `axis_t.steps` 即可 | **采用** |
| LEDC + PCNT | 同上 | 同上 | 可以 | 可以 | LEDC 改频率要重新配置定时器分频，不是为逐周期调速设计的，也没有按周期的中断；不如 MCPWM |

这里没有采用 PCNT 观察点（watch point）在目标步数处停：ESP32-S3 的 PCNT 修改阈值后要清零计数器才生效，这和"运行中延长目标"相冲突。所以停止由每周期中断决定，PCNT 只负责精确计数。

### 4.2 每个通道的硬件

- **MCPWM 定时器**：1 MHz 分辨率，向上计数，`update_period_on_empty`，即新周期在下一个 TEZ（计数归零）时生效，不会产生毛刺。周期是 16 位，所以最低速度约 15 步/秒，远低于 `V_START_SPS`。
- **比较器**：`update_cmp_on_tez`，比较值 = 周期 / 2。
- **生成器**（STEP 脚，`io_loop_back` 打开，让 PCNT 能读到同一个脚）：**TEZ → 低，比较匹配 → 高**。上升沿在每个周期的中点，占空比 50 %。这样选择动作是为了让定时器停在 0 时输出的"自然电平"是低，空闲时撤掉强制电平不会产生多余的边沿。
- **PCNT**：边沿输入 = STEP 脚，上升沿 +1。打开 `accum_count`，并把上下限加为观察点（IDF 文档的要求），使计数超过 16 位时由驱动累加。按默认机械参数，全行程是 23200 步，本来就不会溢出。
- **GPIO**：DIR 输出；LIMIT 输入（上拉）。
- 资源分配：MCPWM 组 0 的定时器 0/1、操作器 0/1；PCNT 单元 0/1。两个通道之间不共享任何硬件和锁。

### 4.3 一次运动的流程

```
任务  stepper_start(ch, dir, steps, tag)
        先停下该通道（如果在动）；读一次限位开关
        axis_start(ax, dir, steps, limit)         → 拒绝时直接返回（不动）
        设置 DIR；清零 PCNT
        p = axis_next(ax, 0, limit)               → 第一个周期的长度
        设置周期 p、比较值 p/2；撤掉强制电平；启动定时器
ISR   每个 TEZ：n = PCNT 计数；limit = 读开关
        p = axis_next(ax, n, limit)
        p > 0  → 设置下一个周期 p、比较值 p/2
        p == 0 → 强制输出低（保持）；定时器 STOP_EMPTY；
                 n' = PCNT 计数；axis_finish(ax, n')；回调 on_end(ch, status, tag)
任务  stepper_halt(ch)：临界区内强制低、停定时器、axis_finish(ax, PCNT 计数)。不回调
任务  stepper_extend(ch, dir, steps)：临界区内 axis_extend()
```

注意：`STOP_EMPTY` 之后定时器还会再归零一次，触发最后一次 TEZ 中断。ISR 要先检查该通道是否还在运行，不在运行就直接返回，不能重复停止或重复回调。

**停止后再启动**：
- **先等定时器停稳。** 启动前必须等上一段运动的定时器真正停下，即 `on_stop` 中断把 `idle` 置位。否则 START 会取消还没生效的 STOP_EMPTY，并且在旧周期中途撤掉保持电平，比较匹配可能产生多余的上升沿。最多等两个最长周期（默认 5 ms），用忙等；只有在"停下后立即换向或重启"时才会出现。
- **停止时预装起步周期。** 停止时（ISR 停止和 halt 都算），先把影子周期和比较值写成 `v_start` 对应的值，让停止那次 TEZ 把它装入。这样下次启动的第一个周期总是 `v_start`，与启动时是否触发 TEZ 无关。
- **速度曲线滞后一个周期。** ISR 写入的周期要到下一个周期才生效，所以速度曲线整体滞后一个周期，不影响步数。
- **引脚和限位读取。**
  - STEP 引脚先用 `gpio_config(GPIO_MODE_INPUT_OUTPUT)` 打开输入通路，替代 v6.0 将要删除的 `io_loop_back`。
  - 限位开关在 ISR 里用 `gpio_ll_get_level` 读取，它是内联函数，位于 IRAM。

**为什么步数是精确的**：在第 k 个周期开头，ISR 读到的 PCNT 值正好是前 k−1 个周期发出的脉冲数。如果决定停，强制低电平发生在本周期的中点之前（ISR 延迟只有几微秒，而半个周期 ≥ 400 µs），所以本周期没有上升沿；如果中途被强制拉低时上升沿已经发生，那么这个脉冲驱动器收到了，PCNT 也计到了。两种情况下，`axis_finish()` 用的都是**最终的 PCNT 值**，它和驱动器实际收到的步数一致。即使某次中断被推迟了一整个周期，计数也不会错，最多是多走一步，而且会被如实计入位置。

**限位立即停**：开关在每个周期开头被采样，也就是在每个脉冲发出之前采样一次；连续 `LIMIT_DEBOUNCE`（2）次有效即停止。因此最多多走 1 步（0.4 µL）。不需要单独的 GPIO 中断。两次采样相隔一个周期，相当于滤掉短于一个周期（1212 步/秒时约 0.8 ms）的毛刺。

**CPU 占用**：每步一次中断，耗时约 2–3 µs。默认最高速度下每通道 1212 次/秒，约占 0.3 % CPU；即使导程是 2 mm（4850 次/秒），也只有约 1.5 %。中断里只做整数运算，不翻转 GPIO。

**IRAM**：`CONFIG_MCPWM_ISR_HANDLER_IN_IRAM`、`CONFIG_MCPWM_CTRL_FUNC_IN_IRAM`（`mcpwm_timer_set_period`、`mcpwm_comparator_set_compare_value`）、`CONFIG_PCNT_CTRL_FUNC_IN_IRAM`（`pcnt_unit_get_count`），以及 `core/linker.lf` 把 `axis.c` 放进 IRAM。强制电平和启停定时器的函数在 Flash 里，但只在停止时调用一次；运动期间不会写 Flash（`cal_set` 只在 idle 时接受），所以 ISR 不需要做成 cache-safe。

**没有电机也能验证**（清单见第 19 节）：PCNT 通过回环计的就是 STEP 脚，所以在一块裸 DevKitC 上就能检查"命令 N 步 → PCNT = N"。用一根杜邦线把 LIMIT 脚接到 GND 或 3V3，就能模拟开关。

### 4.4 速度曲线（`axis.c`，只用整数）

- 速度用 `v_q8` 表示，单位是"步/秒 × 256"。周期 = 256 000 000 / v_q8 µs。
- 每个周期速度变化 Δv_q8 = accel × period_us / 3906（即 a·dt·256）。按 `config.h` 的取值，乘积最大为 8000 × 2500 = 2×10⁷，不会溢出 32 位。
- 停止距离 = (v² − v_start²) / (2·accel)，单位是步。剩余距离（有限运动是剩余步数；向吸满方向运动时，还要和到软限位的距离取较小值）小于等于停止距离时减速，否则加速到 `v_max`。
- 默认值：从 400 步/秒加速到 1212 步/秒需要 0.1 s、82 步（34 µL）；一次 50 µL 的 `move`（121 步）是三角形速度曲线。
- 立即停止（`stop`、限位、换向）不减速：最高转速只有 0.38 转/秒，低于 42 步进电机不失步的启停速度。如果以后提高速度，这一点需要重新评估。

---

## 5. BLE（NimBLE）

对照协议第 1 节：

| 项 | 实现 |
|---|---|
| 服务 | `f65c0001-8221-4068-aa47-28e41eec47fd`，主服务 |
| CMD | `f65c0002-…`，`BLE_GATT_CHR_F_WRITE`（只支持带响应的写，不加 `WRITE_NO_RSP`） |
| EVT | `f65c0003-…`，`BLE_GATT_CHR_F_NOTIFY`（CCCD 由 NimBLE 自动添加） |
| 写回调 | 用 `ble_hs_mbuf_to_flat()` 拷到栈上缓冲区（最多 `PROTO_MAX_MSG + 1` 字节，`len` 传真实长度），调用 `on_write`，**总是返回 0**，不回 ATT 错误；结果通过 `error` 事件上报 |
| 订阅 | `BLE_GAP_EVENT_SUBSCRIBE`，`attr_handle` 是 EVT 且 `cur_notify` 置位时调用 `on_subscribe` → 设备发出 `state` 和 `cal` |
| 广播 | 广播包：flags + 128 位服务 UUID（3 + 18 = 21 B）。扫描响应：完整名称 `Titrator-XXXX`，XXXX 是 BT MAC 最后两个字节的十六进制。可连接、无定向，使用默认广播间隔 |
| 连接数 | `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1`。可连接广播在建立连接时由协议栈自动停止；`BLE_GAP_EVENT_DISCONNECT` 时调用 `on_disconnect` 并**立即重新广播**；广播结束事件（ADV_COMPLETE）也重新广播 |
| MTU | `CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=247`；由 App 发起交换，小于 103 时由 App 断开。固件不判断 |
| 通知 | `ble_gatts_notify_custom(conn, evt_handle, om)`，可以在任意任务中调用；没有订阅时直接丢弃；mbuf 申请失败时丢弃并记日志 |
| 安全 | 不配对、不加密（协议没有要求）。保留 IDF 默认的 SM 配置，不主动调用 |
| 角色 | 关闭 central 和 observer，减小体积 |
| 设备名 | `ble_svc_gap_device_name_set()` 在同步回调（`on_sync`）里设置，此时才能拿到地址 |

参考示例：`$IDF_PATH/examples/bluetooth/nimble/bleprph`。

---

## 6. 状态机

状态：`idle`、`titrating`、`moving`（协议 2.2）。此外设备内部还记着当前运动 `motion`（`NONE` / `MOVE` / `JOG` / `DOSE`，带通道、方向、tag、jog 截止时间），任何时刻最多一个。

**命令处理顺序**：先解析（失败 → `error: bad_cmd` + `msg`），再查状态表（不接受 → `error: busy`），最后执行。这和模拟器有一个细微差别：模拟器先查状态，再检查参数范围。所以"移动中收到参数越界的 `cal_set`"在固件里回 `bad_cmd`，在模拟器里回 `busy`。协议没有规定两者的先后，App 对两者的处理一样。

| 当前状态 | 命令 | 动作 | 事件 |
|---|---|---|---|
| idle | `titrate` | 电极异常中 → 拒绝；否则 `titr_start` | `error: sensor`；或 `state: titrating` |
| idle | `cal_set` | 保存到 NVS 并立即生效（保存失败也生效，记日志） | `cal` |
| 任意 | `stop` | 停下当前运动，结束滴定 | 状态有变化时 `state: idle` |
| 任意 | `move` / `jog` | 见下 | — |
| titrating / moving | `titrate` / `cal_set` | — | `error: busy` |

**`move` / `jog`**

1. 当前运动是 `MOVE` 或 `JOG`，并且通道和方向相同：
   - `move` 遇到 `MOVE`：`motor_extend(+MOVE_STEPS)`（累加）。
   - `move` 遇到 `JOG`：什么都不做，jog 继续。
   - `jog` 遇到 `JOG`：刷新截止时间（当前时间 + `JOG_TIMEOUT_MS`）。
   - `jog` 遇到 `MOVE`：`motor_extend(AXIS_CONTINUOUS)`，转为 `JOG`，设置截止时间。
   - 如果 `motor_extend` 返回 false（那段运动刚好已经结束，但结束消息还在队列里），就按第 2 步重新开始。
2. 否则：停下当前运动（滴定也一并结束，但不发 error），然后 `motor_start(ch, dir, move ? MOVE_STEPS : AXIS_CONTINUOUS, 新 tag)`：
   - 返回 `AXIS_RUNNING` → `motion` 改为新的运动，`state: moving`（如果原来不是 moving）。
   - 返回拒绝 → `error: unhomed` 或 `limit`（带 `ch`、`dir`），然后如果原来不是 idle，再发 `state: idle`。

**设备自己停止**：一律先发 `error`，再发 `state: idle`（协议 2.3）。

| 来源 | 条件 | 事件 |
|---|---|---|
| 运动结束 `AXIS_DONE` | `MOVE` → idle；`DOSE` → `titr_dose_done()`，继续滴定 | `state: idle`（仅 MOVE） |
| 运动结束 `AXIS_LIMIT_OUT` / `AXIS_LIMIT_IN` | 任何运动（包括滴定中的一剂） | `error: limit`（`ch`、`dir`）→ `state: idle` |
| `titr_on_ph` 返回 `TITR_NO_CONVERGE` | — | `error: no_converge` → `state: idle` |
| 进入电极异常 | titrating 时 | `error: sensor` → `state: idle` |
| 进入电极异常 | 其他状态时 | 只发 `error: sensor`，运动继续（与模拟器一致） |
| jog 截止时间已过 | `device_tick` 检测到 | `state: idle`（正常结束，不发 error） |
| 断开连接 | 停下一切 | `state: idle`（此时没有接收方，丢弃无妨） |

`state` 只在发生变化时发送，另外在订阅时发送一次（随后发 `cal`）。`ph` 事件每收到一个有效采样发一次，与状态无关。

---

## 7. 归位和软限位

全部在 `axis.c` 中实现，位置只存在 RAM 里（协议第 3 节）。

- `pos`：从排空端（开关位置）算起的步数，向吸液方向为正。上电时 `homed = false`。
- **排液（out）**：开始时开关已经有效 → 拒绝，返回 `AXIS_LIMIT_OUT`，同时 `pos = 0`、`homed = true`（开关有效就说明在端点，这本身就是一次归位）。运动中开关连续 `LIMIT_DEBOUNCE` 次有效 → 停止，`pos = 0`、`homed = true`，返回 `AXIS_LIMIT_OUT`。未归位时照常排液，滴定也照常进行。
- **吸液（in）**：未归位 → 拒绝，返回 `AXIS_UNHOMED`。已归位且 `pos >= STROKE_STEPS` → 拒绝，返回 `AXIS_LIMIT_IN`；运动中到达 `STROKE_STEPS` → 停止，返回 `AXIS_LIMIT_IN`。减速规划会把到软限位的距离算进去。
- **回差**：方向反转后，运动开头先发 `BACKLASH_STEPS` 个不计入位置的脉冲（默认值 0 **[待实测]**）。上电后的第一次运动不加。
- **位置结算**：`pos = pos0 ± max(0, n − backlash)`，n 是最终的 PCNT 计数。
- 开关在运动以外的时间不监视（例如手动推动活塞），也不需要监视。

---

## 8. 滴定控制环

与协议第 4 节和 `app/lib/sim/sim_titrator.dart`（v3）的 `_control` / `_decide` 一一对应，常量同名同值（第 12 节）。

1. **等稳定**：滴定开始、每剂**送完**、每次"保持"决定之后，重新开始等待。`SETTLE_SKIP_MS` 内的读数丢弃；之后把读数放进长度为 `SETTLE_N` 的窗口。窗口满且极差 ≤ `SETTLE_SPAN_PH`，或者等待已达 `SETTLE_MAX_MS`，就用**窗口平均值**做决定。
2. **保持带**：|target − pH| ≤ `HOLD_TOL_PH` 时不加液，重新等待。完成由 App 判定（连续 5 s 在 ±0.05 以内，且这 5 s 内读数极差 ≤ 0.03，与 `SETTLE_SPAN_PH` 相同），之后 App 发送 `stop`。
3. **方向**：pH 高于目标加酸（通道 1），低于目标加碱（通道 2）。
4. **剂量**：第一剂 `FIRST_DOSE_UL`。之后计算 gain =（上一剂是碱则取 +1，是酸则取 −1）×（本次 pH − 上一剂决定时的 pH）。gain ≥ `SETTLE_SPAN_PH` 时，剂量 = `DOSE_GAIN` × |err| × 上一剂 / gain；否则为上一剂的 2 倍。
5. **换向**：方向和上一剂不同时，记一次换向。累计到第 `MAX_REVERSALS` 次，或者上一剂已经是 `MIN_DOSE_UL`，就返回 `TITR_NO_CONVERGE`；否则剂量减半。
6. 限幅到 [`MIN_DOSE_UL`, `MAX_DOSE_UL`]。
7. **执行**：步数 = round(µL / `UL_PER_STEP`)（至少 1 步），`motor_start(ch, DIR_OUT, steps)`。送完（`AXIS_DONE`）后调用 `titr_dose_done()`。送液过程中到达排空端 → `error: limit`（`ch`、`out`）→ idle。

**与模拟器唯一的差别**：模拟器里加液是瞬间完成的，等待从加液那一刻开始计；固件的等待从送完那一刻开始计（`titr_dose_done`）。

**节奏**：每轮至少要"送液时间 + 2 s + 4 s"。缓冲样品通常 5–10 剂收敛，约 1 分钟。最大一剂 500 µL 送液约 1 s。

---

## 9. 电极异常判定

- 一个采样"贴近量程两端"的条件：ADC 读失败，或者 `V_adc` ≤ `SENSOR_RAIL_LO_MV`（150 mV，对应 Po 0.375 V，正常电极不可能出现），或者 `V_adc` ≥ `SENSOR_RAIL_HI_MV`（1380 mV，对应 Po 3.45 V，接近 LM358 的饱和电压）。**[待实测]** 联调时拔掉电极、短接 BNC、拔掉 Po 线，分别记录 `V_adc`，据此确定这两个阈值。
- 从第一个贴边的采样开始计时，连续贴边达到 `SENSOR_FAULT_MS`（2 s）即进入异常，`sensor_fault_update` **只在进入时返回一次 true**。2 Hz 采样下，实际在 2.0–2.5 s 之间判定。
- 出现一个正常采样就退出异常，不发事件。之后再次进入时会再报一次。
- 异常期间，`ph` 照常上报（读失败的那个窗口没有数据，不报）；收到 `titrate` 回 `error: sensor`。
- 注意：PH-4502C 在 pH 低于约 1.6 时 Po 会饱和，这时也会被判为异常。这是模块本身的量程限制，属于如实上报。

---

## 10. pH 测量链

```
电极 ──► PH-4502C（5 V，增益约 3，偏置 2.5 V）──Po──► 15k/10k 分压 + 100 nF ──► GPIO1（ADC1_CH0，6 dB）
        ──► DMA 10 kSPS ──► 每 5000 个采样（500 ms）求原始码均值 ──► 曲线校准分段线性表 ──► V_adc（mV，浮点）
        ──► MSG_SAMPLE ──► device_on_sample:
               sensor_fault_update(at_rail(V_adc))
               mv = (V_adc − FE_BIAS_MV) / FE_GAIN
               pH = 7 + (mv − offset) / slope
               emit {"evt":"ph","v":pH(2 位小数),"mv":mv(1 位小数)}
               滴定中、不在送液且不在贴边：titr_on_ph(pH)
```

- `ph` 的频率由 ADC 采样个数决定，稳定在 2 Hz，不依赖 FreeRTOS 的 tick。
- 设备没有实时时钟，时间戳由 App 在收到时打（协议 2.2）。
- 不做温度补偿（协议 2.4）。

---

## 11. NVS 存储

- 只存标定参数：命名空间 `titrator`，键 `cal`，blob 为 `{uint8_t version = 1; float slope; float offset;}`。读出后用 `ph_cal_valid()` 校验，不合法或不存在时使用出厂值（−59.16 / 0）。
- 只在 `cal_set` 时写入（只有 idle 时接受这个命令，所以写 Flash 时电机一定是停着的），写入频率极低，不需要考虑磨损。
- `nvs_flash_init()` 遇到 `ESP_ERR_NVS_NO_FREE_PAGES` 或 `ESP_ERR_NVS_NEW_VERSION_FOUND` 时擦除后重试。BT 控制器也依赖 NVS（存 PHY 校准数据），所以它是 `app_main` 的第一步。
- 注射器位置和归位状态**不写 NVS**（协议第 3 节）。

---

## 12. `config.h` 常量清单

默认值以 `components/core/include/core/config.h` 为准，接线常量在 `platform/board.h`。

| 常量 | 默认值 | 单位 | 说明 |
|---|---|---|---|
| `MOTOR_FULL_STEPS` | 200 | 步/转 | 1.8° 电机 **[待确认]** |
| `MICROSTEPS` | 16 | — | MS1 = MS2 = VIO |
| `LEAD_MM` | 8.0 | mm/转 | T8 丝杆导程 **[待确认]** |
| `SYRINGE_UL_PER_MM` | 165 | µL/mm | 10 mL 注射器，内径约 14.5 mm **[待确认]** |
| `STROKE_MM` | 58 | mm | 从开关算起的可用行程 **[待确认]** |
| `STEPS_PER_MM` | 400 | 步/mm | 推导值 |
| `UL_PER_STEP` | 0.4125 | µL/步 | 推导值 |
| `STROKE_STEPS` | 23200 | 步 | 推导值，软限位（约 9.57 mL） |
| `MOVE_UL` / `MOVE_STEPS` | 50 / 121 | µL / 步 | 一次 `move`，与模拟器相同 |
| `PUMP_UL_PER_S` | 500 | µL/s | 最高速度，与模拟器相同 |
| `V_MAX_SPS` | 1212 | 步/s | 推导值，0.38 转/秒 |
| `V_START_SPS` | 400 | 步/s | 启停速度 |
| `ACCEL_SPS2` | 8000 | 步/s² | |
| `BACKLASH_STEPS` | 0 | 步 | **[待实测]** |
| `LIMIT_DEBOUNCE` | 2 | 次 | 连续有效采样次数 |
| `JOG_TIMEOUT_MS` | 1000 | ms | 协议 2.1 |
| `SAMPLE_PERIOD_MS` | 500 | ms | `ph` 2 Hz，同时是 ADC 平均窗口 |
| `FE_MODULE_GAIN` | 3.0 | — | **[待实测]** |
| `FE_DIVIDER` | 0.4 | — | 15k/10k **[待确认]** |
| `FE_GAIN` | 1.2 | — | 推导值，含分压比（协议 2.4） |
| `FE_BIAS_MV` | 1000 | mV | BNC 短接时的 ADC 读数 **[待实测]** |
| `SENSOR_RAIL_LO_MV` / `HI_MV` | 150 / 1380 | mV | ADC 端 **[待实测]** |
| `SENSOR_FAULT_MS` | 2000 | ms | 协议第 3 节 |
| `CAL_DEFAULT_SLOPE` / `OFFSET` | −59.16 / 0 | mV/pH / mV | 协议 2.4 |
| `CAL_SLOPE_MIN..MAX` | −70 … −40 | mV/pH | `cal_set` 的取值范围 |
| `CAL_OFFSET_MIN..MAX` | −100 … 100 | mV | |
| `TARGET_PH_MIN..MAX` | 0 … 14 | pH | |
| `SETTLE_SKIP_MS` | 2000 | ms | 与模拟器 `settleSkip` 相同 |
| `SETTLE_N` | 8 | 个 | `settleN` |
| `SETTLE_SPAN_PH` | 0.03 | pH | `settleSpan`，同时是"响应太小"的判据 |
| `SETTLE_MAX_MS` | 30000 | ms | `settleMax` |
| `HOLD_TOL_PH` | 0.02 | pH | `holdTol`，必须小于 App 的 0.05 |
| `FIRST_DOSE_UL` / `MIN_DOSE_UL` / `MAX_DOSE_UL` | 50 / 5 / 500 | µL | `firstDoseMl` 等 |
| `DOSE_GAIN` | 0.5 | — | |
| `MAX_REVERSALS` | 3 | 次 | `maxReversals` |

`main.c` 中的：`CTL_TICK_MS` 50、`CTL_QUEUE_LEN` 16、任务优先级和栈大小。`board.h` 中的：引脚、DIR 和限位的有效电平、`BOARD_PH_ADC_SAMPLE_HZ` 10000。

---

## 13. 引脚规划（草案，**[待硬件确认]**）

| 功能 | GPIO | 排针 | 说明 |
|---|---|---|---|
| CH1 STEP | 4 | J1-4 | MCPWM0 定时器 0 |
| CH1 DIR | 5 | J1-5 | |
| CH2 STEP | 6 | J1-6 | MCPWM0 定时器 1 |
| CH2 DIR | 7 | J1-7 | |
| EN（两路共用） | 15 | J1-8 | 低有效，10 kΩ 上拉 |
| CH1 限位 | 16 | J1-9 | NC 接 GND，上拉 + 100 nF |
| CH2 限位 | 17 | J1-10 | 同上 |
| pH ADC | 1 | J3-4 | ADC1_CH0；与电机线分在两侧排针，减少数字噪声耦合 |
| 备用 | 2, 8–14, 18, 21, 39–42, 47 | | 以后如果换 ADS1115，I2C 建议用 8/9 |

**避开的引脚**：0、3、45、46（strapping）；19、20（USB）；43、44（UART0 控制台）；26–37（Flash 和八线 PSRAM，其中 35–37 排针上有但被占用）；38、48（板载 RGB LED，v1.1 在 38，v1.0 在 48）。

电机侧的 GPIO4–7、15–17 在 J1 上是连续的 7 个针脚（J1-4 到 J1-10），一根排线就能接完两路驱动和两个开关。

---

## 14. 主机测试策略

**框架：ESP-IDF 自带的 Unity 源码**（`components/unity/unity/src/unity.c`）。理由：主机测试本来就要从 IDF 源码树里编译 cJSON，Unity 也在同一棵树里，不多引入任何依赖；它的浮点断言（`TEST_ASSERT_FLOAT_WITHIN`）和逐用例报告比自己写的断言省事；以后如果要在板上跑单元测试，用法也一样。IDF 的路径取自 `IDF_PATH`，默认是 `~/esp/esp-idf-v5.5.5`。

- 每个模块一个可执行文件，由 CTest 驱动。默认打开 ASan 和 UBSan，core 用 `-Wall -Wextra -Werror -Wdouble-promotion` 编译（后者用来发现不小心写出的 double 运算，它在 S3 上是软件模拟的）。
- **`IGNORE` 判为失败**（`FAIL_REGULAR_EXPRESSION ":IGNORE"`）：CTest 把 `IGNORE` 当作失败，这样不会有测试被悄悄留成未实现。
- `CLOG_LEVEL`（CMake 缓存变量，0–4）可以在主机上打开 core 的日志，用来调试闭环测试。

| 测试 | 内容 |
|---|---|
| `test_protocol` | 所有命令的解析、取值边界、非法输入；所有事件的精确文本、长度上限、非有限数 |
| `test_ph` | 2.4 节换算、标定参数范围 |
| `test_sensor_fault` | 2 s 持续、只报一次、恢复、再次进入、时间回绕 |
| `test_axis` | 像 ISR 一样逐周期调用 `axis_next`：步数精确、梯形和三角形速度曲线、去抖、归位、软限位、延长、中止、回差、不溢出 |
| `test_titration` | 第 8 节每一条规则，包括和模拟器相同的决策 |
| `test_device` | 用记录调用的假端口验证第 6 节的完整状态表和事件顺序 |
| `test_beaker` | 烧杯模型对照教科书数值 |
| `test_closed_loop` | **带模拟烧杯的闭环**（`sim/rig.c`）：真实的 `device` + `axis` + `titration`，加上模拟电极（−57.4 mV/pH、+6.5 mV、1.5 s 一阶滞后、0.25 mV 噪声）、前端换算、带开关的注射器、App 的完成判定。用例：缓冲样品在 3×3 种起点/目标组合下都能收敛；无缓冲样品报 `no_converge`；试剂用完报 `limit`；滴定中电极故障报 `sensor`；手动归位流程中位置与模拟一致 |

测试台按 `axis_next()` 返回的周期逐步推进电机，这正是 MCPWM 在板上做的事，所以闭环测试也覆盖了步数结算。

---

## 15. 日志和版本

- 版本号：`firmware/version.txt`（现在是 `0.1.0`），由 IDF 写入 `esp_app_desc`。启动时打印一行 `titrator firmware 0.1.0, protocol v3, ESP-IDF v5.5.5`。发布时改 `version.txt`，不使用 git describe（仓库里还有 App 代码，提交哈希对固件没有意义）。
- 日志级别：默认 INFO，最高编译到 DEBUG（可以在运行时用 `esp_log_level_set` 对单个 tag 打开）；NimBLE 设为 WARNING。
- tag：`main`、`ble`、`stepper`、`ph_adc`、`cal`、`device`、`titr`。
- INFO 级别要记录的内容：状态变化；每次滴定决策（pH、误差、通道、µL、换向次数）；每次运动的结束原因和位置；电极异常的进入和退出；标定参数的保存；连接、断开和 MTU。DEBUG 级别：每条命令原文、每个 `V_adc` 读数。WARN 级别：队列满、通知失败、NVS 失败、PCNT 计数与预期不符。
- ISR（`axis.c`、`stepper.c` 的中断部分）不打日志。

---

## 16. 构建和烧录

```bash
. ~/esp/esp-idf-v5.5.5/export.sh
cd firmware
idf.py build                               # 目标芯片取自 sdkconfig.defaults，不需要 set-target
idf.py -p /dev/ttyACM0 flash monitor       # 板上 USB 转串口那个口（UART0 控制台）；串口芯片是 CP2102N 时为 /dev/ttyUSB0
idf.py -p /dev/ttyACM0 flash monitor       # 原生 USB 口（USB-Serial-JTAG）；两个口都插着时编号看插入顺序，用 /dev/serial/by-id/ 区分
idf.py menuconfig                          # 改完后用 idf.py save-defconfig 写回 sdkconfig.defaults
```

烧录要求用户在串口组里（Ubuntu / Debian 是 `dialout`，Arch / CachyOS / Manjaro 是 `uucp`），否则 `idf.py flash` 报 `Permission denied`：先 `sudo usermod -aG dialout $USER`（Arch 系换成 `uucp`），再注销重新登录（只想让当前终端生效用 `newgrp dialout` 或 `newgrp uucp`），`id -nG` 的输出里要有这个组，详见 `docs/DEV_GUIDE.md` 3.1。

主机测试（不需要 ESP-IDF 工具链，只需要 IDF 源码）：

```bash
cmake -S firmware/test/host -B firmware/test/host/build -G Ninja
cmake --build firmware/test/host/build
ctest --test-dir firmware/test/host/build --output-on-failure
```

`sdkconfig` 只在 `firmware/sdkconfig` 不存在时才由 `sdkconfig.defaults` 生成；改了 `sdkconfig.defaults`（例如更换板卡）以后，先删除 `firmware/sdkconfig` 再 `idf.py build`。

---

## 17. 不做和不建议做的事

| 事项 | 理由 |
|---|---|
| TMC2209 UART 配置 | 电流用 VREF 电位器调，微步用跳线定，内插独立模式下本来就开着；UART 会多一个外设、半双工协议和上电初始化，没有实际收益 |
| **StallGuard 无传感器回零** | 需要 UART 和 StealthChop，并且转速要高于一定阈值才可靠；注射器丝杆转速低（0.38 转/秒）、负载小，失速信号弱，容易误判；用堵转来找端点，会让活塞撞上注射器底部，可能压裂注射器或损坏活塞；而且协议已经约定用排空端的限位开关归位 |
| CoolStep、DIAG/INDEX 引脚 | 同上，没有需求 |
| 运行中切换微步 | 只有一种速度曲线，没有必要 |
| 上电自动回零 | 协议约定由用户排液到底完成归位；上电时自动运动可能把液体推出去 |
| 位置写入 NVS | 协议明确规定不写；断电期间可能被手动推动，存下来的位置不可信 |
| OTA、配对加密、多连接 | 不需要（协议规定只允许 1 个连接） |
| 编码器闭环 | 没有编码器；PCNT 已经保证"发了多少步就记多少步" |
| 外置 ADC 驱动 | 内部 ADC 按数字估算已经足够（第 1.3 节）；只有在实测 INL 不合格时才换，接口已经预留 |
| 温度补偿、To/Do | 协议约定不做温度补偿；To 测的是电路板温度，Do 没有用处 |
| Wi-Fi | 协议只定义了 BLE |
| 板载 RGB LED 状态灯 | 需求里没有；以后要加，可以用 RMT 驱动（GPIO38 或 GPIO48，取决于板卡版本） |
| 停止时减速 | 当前速度很低，立即停止不会失步；如果减速，`stop` 后还会多推出几十微升 |

---

## 18. 待确认清单

**机械和电机**
1. 丝杆导程（默认 8 mm，T8×8？）、注射器规格（默认 10 mL，内径约 14.5 mm）、从开关算起的可用行程（默认 58 mm）。这三个数决定了 `UL_PER_STEP` 和 `STROKE_STEPS`。
2. 电机型号和额定电流（用来调 VREF）；电机电源电压（12 V 还是 24 V）。
3. 每个通道哪个 DIR 电平对应排液（取决于接线，可以通过 `BOARD_DIR_OUT_LEVEL` 调整）。
4. 回差步数（实测）。

**TMC2209 模块**
5. 模块板上 EN 有没有上拉或下拉电阻（决定是否外加 10 kΩ 上拉）。
6. PDN、CLK 在模块板上是否已经接地；USART 是否经 1 kΩ 接到 PDN_UART（对照模块原理图）。
7. MS1/MS2 是否可以直接接 VIO（有的模块用跳线帽）。

**限位开关**
8. 开关类型：机械开关的常闭（NC）还是常开（NO）触点，或者光电开关（如果是 5 V 输出，需要分压）。走线长度（决定 RC 滤波的取值）。

**pH 前端**
9. PH-4502C 实际的增益和极性（假定为同相，约 3.0）；pH 7 时的 Po；LM358 的饱和电压（决定 `SENSOR_RAIL_HI_MV`）。
10. 拔掉电极、短接 BNC、拔掉 Po 线三种情况下的 `V_adc`（决定电极异常的阈值）。
11. 分压电阻的实际取值（默认 15k/10k，用 1 % 精度）。
12. **ESP32-S3 ADC 在 0.7–1.3 V 区间的线性度**（第 1.3 节的验收测量）。不合格就换 ADS1115，这是本设计里唯一的"假设可能不成立"的地方。

**板卡**
13. 模组丝印确实是 ESP32-S3-WROOM-1-N16R8，并确认板卡版本（v1.0 的 RGB LED 在 GPIO48，v1.1 在 GPIO38；两个都避开了，所以接线不依赖这一点）。
14. 整机供电方案：USB 5 V 同时给 ESP32 和 PH-4502C 供电，电机电源另接，所有地接在一起（建议星形接地，pH 信号地单独回到 ESP32 的 GND）。

---

## 19. 上板验证清单

下面这些都还没有在硬件上验证过。除特别说明外，用一块只有 1.05 V 分压（见第 1.3 节）、没有接电机的裸板即可。

**ADC 与标定存储**
- GPIO1 接 1.05 V 分压：日志里的 `V_adc` 稳定。
- 第 1.3 节的验收测量（0.7–1.3 V 之间约 10 个电压点，直线拟合残差 ≤ 1.2 mV）；不合格就换 ADS1115。
- 接上 PH-4502C 模块后，拔掉电极、短接 BNC、拔掉 Po 线，分别记录 `V_adc`，确定 `SENSOR_RAIL_LO_MV` / `SENSOR_RAIL_HI_MV`（第 9 节）。
- `cal_store`：`cal_set` 写入后重启，标定仍然生效。

**步进（不接驱动）**
- 命令 1、121、1212、23200 步，PCNT 计数都与命令完全相等。
- 运行中 halt 后，位置等于 PCNT 计数。
- 用杜邦线把 LIMIT 脚拉到有效电平，排液在 2 步以内停止。
- 用逻辑分析仪或示波器检查启停时没有多余的边沿（重点：第一个周期使用新的周期值、撤掉强制电平时没有上升沿）。

**BLE**
- App 能扫描到 `Titrator-XXXX`，排在列表最前面；连接后收到 `state` 和 `cal`，`ph` 以 2 Hz 上报。
- `cal_set` 保存后重启，仍然生效。
- 断开后能立即重新连上。
- 写入一个 101 B 的命令，回 `bad_cmd`。
- 用 nRF Connect 检查广播包是 21 B、设备名在扫描响应里。

**任务栈**
- 做完一次滴定和一次 `cal_set` 后，查看各任务的栈高水位（代码里现在没有打印，需要临时加日志调用 `uxTaskGetStackHighWaterMark`），确认余量够用。
