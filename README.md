# SketchUp 空间设计工作室

**v1.2.1 · 候选更新｜真实生成动画、完成状态防陈旧、低开销接入**

面向建筑、室内与空间设计的 Codex Skill，调用 `$sketchup-design-studio`。保留参考还原、尺度控制、中文命名、可编辑构件、局部改稿、场景与 Enscape 工作流，包含 SketchUp 内分步建模的 Ruby 执行器和中文面板。

> 新运行时尚未完成原生 SketchUp 与外部工作台联调。静态/模拟测试不等于几何与宿主兼容性验收。本仓库不包含 SketchUp 或现用外部 Ruby 工作台/连接器。

## 本次更新

| 功能 | 行为 |
|---|---|
| 完成状态防陈旧 | 核对模型内任务标识、版本、步数与最后一步；完成后撤销/重做/后续提交使旧证明失效 |
| 精简状态接口 | `status_brief_json(job_id)` 返回摘要；原全量接口默认行为仍兼容 |
| 失效提示 | 步骤历史仍可为 completed，但 completion_valid=false，面板提示重新验收 |
| 本地通知策略 | 示例将逐步进度留本地，只在需要注意时通知；须接入外部工作台 |
| 资源清理 | 完成后保留轻量观察器；任务上限 16，清出时释放监视器 |
| 规划与验收 | [版本路线图](docs/版本迭代路线图.md)、[实机验收清单](docs/实机验收清单.md) |

保留 v1.2.0 的演示/快速模式、暂停/继续/单步/停止、倍速、独立任务组、重复计划保护与 JSON 记录。局部改稿不为动画重建全案。几何辅助函数仅用于盒体和生长示例，不是完整建筑构件库。

## 安装与试用

详见 [安装与快速开始](安装与快速开始.md)。先备份旧版本到 Skill 扫描目录之外，再替换完整文件夹，不能只复制 SKILL.md。更新后重启 SketchUp，避免 Ruby 缓存混用。

```text
Windows：%USERPROFILE%\.agents\skills\sketchup-design-studio
macOS：~/.agents/skills/sketchup-design-studio
```

目标：SketchUp 2022+ 桌面版 Windows/macOS，仍待实机验证。另建空白测试模型，退出组件编辑，活动标签设为 Untagged/Layer0；模板有默认人物时仅在测试模型中删除。

```ruby
load File.expand_path('~/.agents/skills/sketchup-design-studio/scripts/sketchup_studio.rb')
SketchupDesignStudio::VERSION # 应为 "1.2.1"
SketchupDesignStudio.demo
```

70 步演示：地台 → 四柱长高 → 梁架 → 顶棚格栅 → 坐凳。加载不自动生成、不保存。关窗暂停；重开用 `SketchupDesignStudio.show_panel`。

## 工作台接入

```ruby
# 使用 submit 返回的完整 job_id，在后续独立调用中查询。
puts SketchupDesignStudio.status_brief_json(job_id)
# 诊断才取完整历史。
puts SketchupDesignStudio.status_json(job_id)
# 自动保存/导出前验证执行完成状态。
model = SketchupDesignStudio.assert_completed!(job_id)
```

`submit` 返回不等于完成。工作台本地轮询进度，不让 Astra 每一步发起新回合，不在 SU 主线程 sleep/忙等。详见 [生成动画与接入](references/generation-animation.md)。

门禁核查执行记录和检测到的变更，不替代几何、视觉或法规检查，也不拦截原生保存。完成后检测到同模型提交会保守撤销旧证明，可能包含无关编辑；本版不做对象级归因，不自动重新认证。停止不等于全量撤销，每步有独立撤销记录。

## 文件与验证

`SKILL.md` 为设计入口，`scripts/` 为运行时和面板，`examples/` 为亭架、墙体和本地通知策略，`references/` 为按需文档，`tests/` 为模拟/JavaScript 测试，`tools/` 为检查与测量，`docs/` 为路线图、报告和验收记录。

见 [v1.2.1 修改与测试报告](docs/v1.2.1_修改与测试报告.md)。开发检查：

```bash
python tools/check_repo.py
ruby tools/measure_status.rb
```

仅开发测试需要 Python 3.9+、Ruby + minitest、Node.js 18+；SU 运行不另装这些依赖。CI 配置包括 Ruby 2.7/3.3，是否实际通过以对应提交检查为准。

不自带 Ruby 沙箱、远程服务、视频导出、跨重启恢复、整次单步撤销或自动保存；只运行可信任务代码。原 v1.1.1 住宅/Enscape 案例属于历史记录，不构成新增动画的实机验收。v1.3/v1.4 仅规划，未包含在本版能力中。本技能在原 sketchup-editable-model 能力范围基础上重新组织工作流与命名规则。
