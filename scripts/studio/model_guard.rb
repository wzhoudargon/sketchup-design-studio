# frozen_string_literal: true
module SketchupDesignStudio
  # Best-effort interference detection. SketchUp can defer observer events until
  # commit; this is NOT a model-wide lock or isolation from other extensions.
  class ModelGuard < Sketchup::ModelObserver
    def initialize(runner)
      @runner = runner
    end

    def onTransactionStart(_model)
      changed('检测到其他建模操作；请检查已完成部分后重新提交剩余任务') unless @runner.terminal?
    end

    def onTransactionCommit(_model)
      changed('任务完成后模型发生提交；旧完成证明已失效，需要重新验收') if @runner.state == :completed
    end

    def onTransactionUndo(_model)
      changed('模型发生撤销；旧步骤记录不能再作为完整成果依据')
    end

    def onTransactionRedo(_model)
      changed('模型发生重做；请重新核对模型，不自动恢复旧完成证明')
    end

    def onActivePathChanged(_model)
      changed('生成期间进入或退出了组件编辑；请回到顶层后重新提交任务') unless @runner.terminal?
    end

    def onDeleteModel(_model)
      changed('任务所属模型已关闭')
    end

    private

    def changed(message)
      @runner.invalidate_context!(message) unless @runner.owns_operation?
    end
  end
end
