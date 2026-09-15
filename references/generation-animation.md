# 生成动画与工作台接入

适用：新建建筑、室内或景观构件时，展示 SketchUp 视口中的真实生成过程。
版本：1.2.1。目标环境：SketchUp 2022+ 桌面版；本次未在真实 SketchUp 内验证。

## 1. 先分清三层

```text
Codex + SKILL.md → 本地任务 .rb（明确的 steps）
                        ↓ 已有的授权 Ruby 执行通道
SketchUp 主线程 → 本仓库 Runner → 模型几何 + 中文 HtmlDialog
                        ↑
外部工作台本地调用 status_brief_json / control / assert_completed!
```

仓库原版本只有 Skill 和参考文档，没有外部 Ruby 工作台或连接器源码。本版新增可以从既有通道调用的运行时与协议，不能替不存在的工作台修改传输层。没有自动安装 SketchUp、没有新增 HTTP 端口、MCP 服务或任意代码执行接口。

## 2. 首次加载

Windows Ruby 控制台示例（使用实际路径；正斜线可避免反斜线转义）：

```ruby
load 'C:/Users/你的用户名/.agents/skills/sketchup-design-studio/scripts/sketchup_studio.rb'
```

macOS 示例：

```ruby
load File.expand_path('~/.agents/skills/sketchup-design-studio/scripts/sketchup_studio.rb')
```

加载不创建几何、不清模型、不保存文件、不自动跑演示。更新版本后重启 SketchUp 再加载，避免 Ruby 已缓存的文件混用新旧版本。系统 Ruby 的语法检查不能代替此步骤。

## 3. 将任务组织成步骤

先在模型之外准备纯数据、参数与尺寸；实际几何创建留在步骤函数。参数全程保持明确单位，传入 API 时转为 `.mm` / `.m`。每步不宜承担全层复杂布尔或整片大地形；一次耗时操作无法被计时器强行打断。

```ruby
steps = [
  {
    id: 'floor', phase: '地面', label: '创建楼板',
    action: lambda { |entities, data|
      data[:floor] = SketchupDesignStudio::Geometry.box_mm(
        entities, id: 'floor', name: '楼板 · 展室 · 01',
        origin: [0, 0, 0], size: [6000, 4000, 200]
      )
    }
  }
]
job = SketchupDesignStudio.submit(
  plan_id: 'project.room.v1', title: '展室 · 生成过程',
  steps: steps, mode: :animated, interval: 0.12, speed: 1.0
)
puts job.job_id
```

`action` 接收当前任务组的 `entities` 和仅限本任务的 `data`；`data[:job_id]`、`data[:plan_id]` 已预置，请勿覆盖。对象显示名称按主 Skill，稳定业务标识放在 `sketchup_design_studio` 属性字典中。`Geometry.box_mm` 会写 `logical_id`；使用自己的几何函数时自行维护。

`examples/task_template.rb` 是“楼板 + 连续墙体逐步推拉”的 13 步示例。`examples/animated_pavilion.rb` 是 70 步、26 个构件的演示。辅助盒体函数不是完整建筑生成器；墙洞、门窗关联、异形、现状约束仍需按任务建模，不能拿简单示例替代真实设计。

### 必须遵守的步骤契约

1. 只在 SketchUp 主线程执行，不在步骤里新建线程、`sleep`、忙等、联网或弹模态窗口。
2. 不在步骤函数里调用 `start_operation`、`commit_operation`、`abort_operation`；执行器拥有事务。
3. 不新建 / 切换模型、改变编辑路径、全局删除实体、清库、触发撤销或调用文件保存。新几何写入传入的任务容器。
4. 使用信任的本地 Ruby。运行时不是安全沙箱，无法阻止恶意或违约的 action 修改其他对象、文件、共享材料或打开事务。
5. 不以预先生成完整模型再逐件取消隐藏作为默认动画，也不对最终模型做整体缩放以伪造生长。连续墙柱优先多次推拉同一顶面，不堆叠成一摞薄片。

## 4. 真实状态与完成门禁

第一次 `submit` 返回任务对象，通常处于 `running` 且 `completed = 0`。工作台必须结束当前 Ruby 调用，让 UI 事件循环继续；不能在同一调用内等待它完成。

下一次独立 Ruby 调用：

```ruby
puts SketchupDesignStudio.status_brief_json('上一步返回的完整 job_id')
```

精简状态含 job_id、revision、state、completed/total、phase、completion_valid、completion_reason、错误摘要与警告计数。旧 status_json 默认仍含阶段、最近 20 步与最多 10 条警告。status_json(job_id, detail: :brief) 和 control(..., detail: :brief) 也可返回摘要。

| state | 意义 | 下一步 |
|---|---|---|
| idle | 尚未启动 | 只用于本地构造阶段 |
| running | 任务已接收 / 正在分步生成 | 等待后续独立状态查询 |
| paused | 用户暂停或关闭面板 | 用户继续、单步或停止 |
| completed | 所有步骤已成功提交 | 执行完成门禁，再做几何验收及保存 |
| cancelled | 用户停止，保留已完成部分 | 不当作完整成果、不自动重跑 |
| failed | 执行失败或上下文变化 | 显示错误对象，保留已成功提交部分 |

工作台可在本地每 0.5–1 秒查询一次，不让 Astra 每次发起模型回合，也不在 SU 主线程休眠；暂停时降频或等待用户，终态停止常规轮询，交付前独立核对现状。超时先查询 / 告知用户，不直接重发同一任务。保持原 `job_id`，不要只读“最新任务”而误接其他任务结果。

确认完成后，在**后续独立调用**使用门禁：

```ruby
model = SketchupDesignStudio.assert_completed!('完整 job_id')
# 以下目标应从用户授权的输出位置生成，必须另存新版本。
target = File.expand_path('~/Desktop/展室_v02.skp')
raise '目标已存在，请另选版本名' if File.exist?(target)
raise '保存未成功' unless model.save(target) && File.file?(target)
```

运行时不自动保存；`file_saved_by_runner` 始终为 `false`，不代表其他通道没有保存过。`completed` 只说明步骤历史提交成功；`completion_valid` 表示当前能否通过执行门禁，不等于几何合格。门禁核对六个检查点字段；完成后检测到撤销/重做/后续提交会使旧证明失效，重做不自动恢复。无关编辑也可能保守失效，需要重新验收，不改写检查点绕过。尺寸、节点、法线、开口和保存重开仍按主 Skill 验收。门禁不拦截第三方绕过该函数的直接保存操作。

## 5. 控制接口

```ruby
SketchupDesignStudio.control(job_id, 'pause')
SketchupDesignStudio.control(job_id, 'resume')
SketchupDesignStudio.control(job_id, 'step')       # 仅暂停时推进一步
SketchupDesignStudio.control(job_id, 'speed', 2)   # 0.25–4，面板提供 0.5/1/2/4
SketchupDesignStudio.control(job_id, 'mode', 'fast')
SketchupDesignStudio.control(job_id, 'cancel')
SketchupDesignStudio.show_panel(job_id)
SketchupDesignStudio.job(job_id).write_report('C:/实际目录/新任务记录.json')
```

默认显示中文面板；明确不需要面板时 `submit(..., panel: false)`。没有面板时控制依靠工作台或 Ruby 控制台。关闭面板暂停而不销毁任务，重新打开可继续。停止 / 失败为终态，不支持自动重试失败步骤或跨重启恢复；检查后生成剩余任务的新方案。

同一会话仅允许一个活跃任务（包括暂停）。同一模型顶层存在相同 `plan_id` 的任务组时拒绝重复创建；改名不绕过检查。要创建变体须显式更改 `plan_id`，保留旧成果。不要用随机 id 掩盖误重试，不能只因失败就删除原组。记录文件采用独占创建，拒绝覆盖。

## 6. 调度、事务与性能

演示模式每个单次计时器执行一个几何步骤。快速模式使用同一数组，每次最多 32 步或约 12ms 调度预算后交还 UI；单个步骤本身超过预算时只能等该步完成。超过 200ms 的步骤会产生拆分建议。倍速调节展示间隔，不能保证固定帧率或加速几何计算。

每步一事务，在提交后 `active_view.invalidate` 请求重绘。不跨回调保留事务，不使用透明事务把用户手工操作卷入一次撤销，不用持续 `refresh` 硬刷。停止不是全量回滚；按 SketchUp 原生撤销会出现多个步骤记录。必要时停止后人工选中独立任务组删除；运行时不会自动清理共享材料、组件定义或用户模型。

默认相机不变，不自动缩放、不新增 SU 场景。只有空白模型演示设置一次示例机位。浏览模型时可平移、环绕、缩放，但不要编辑模型 / 执行撤销；模型观察器会对检测到的外部事务标记失效，在下一次调度或继续时停止。观察器可能延迟触发，并非对其他扩展的强隔离锁；不能保证识别所有外部修改。

## 7. 本地进度与模型通知分离

`examples/workbench_notification_policy.js` 是纯本地 Node.js 策略，输入精简状态并返回是否值得通知；无网络、模型调用或调度器，未自动接入现有工作台。

```javascript
const {createNotificationPolicy} = require('./examples/workbench_notification_policy');
const shouldNotify = createNotificationPolicy();
// 由工作台本地查询后调用；不要让 Astra 发起每次轮询。
function handleLocalStatus(status) {
  if (shouldNotify(status)) {
    // 通过已有授权通道通知暂停、失败、停止、完成或完成证明失效。
  }
}
```

按 job_id 去重，低 revision 旧响应忽略。revision 是执行器通知序号，不是模型内容版本；相同 revision 下 completion_valid 的变化仍需处理。最近最多 16 个任务，重启或淘汰后可能重新通知，需要持久去重时由工作台实现。

正常 70 条进度示例可仅通知一次完成，不保证每个实际任务都如此。错误、用户干预及需决策阶段不能隐藏。完整日志按需读取；没有外部工作台接入不能承诺减少真实模型回合或会员额度。

## 8. 实机验收

在模型副本中验证加载、演示、暂停 / 单步 / 继续、切速、切模式、关窗重开、停止保留、同任务重复提交、模型切换及撤销保护。分别运行快速与演示模式，核对构件数、位置、尺寸、可编辑性、法线与材料；保存重开后检查属性和场景。不要在未备份的项目上首次测试。

本次仅进行了系统 Ruby、模拟 SketchUp API、JavaScript 和浏览器层检查。真实 SketchUp 几何、CEF 面板回调、工作台通道及保存重开必须现场验收。

详细记录见 [实机验收清单](../docs/实机验收清单.md)。

## 官方 API 依据

- [UI.start_timer / stop_timer](https://ruby.sketchup.com/UI.html#start_timer-class_method)
- [Model：事务、保存与编辑上下文](https://ruby.sketchup.com/Sketchup/Model.html)
- [View.invalidate](https://ruby.sketchup.com/Sketchup/View.html#invalidate-instance_method)
- [HtmlDialog：异步回调与窗口生命周期](https://ruby.sketchup.com/UI/HtmlDialog.html)
- [ModelObserver：模型事件与回调时序](https://ruby.sketchup.com/Sketchup/ModelObserver.html)
