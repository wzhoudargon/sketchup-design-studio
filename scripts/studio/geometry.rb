# frozen_string_literal: true
module SketchupDesignStudio
  module Geometry
    module_function

    # Small, optional helper for examples/templates; not a full building generator.
    # Inputs are millimetres; stored SketchUp geometry is converted with .mm.
    def box_mm(entities, id:, name:, origin:, size:, material: nil)
      xyz = vector(origin, 'origin', positive: false)
      whd = vector(size, 'size', positive: true)
      raise ArgumentError, 'id 与 name 必须为非空字符串' unless [id, name].all? { |v| v.is_a?(String) && !v.strip.empty? }
      if entities.any? { |e| e.respond_to?(:get_attribute) && e.get_attribute(DICTIONARY, 'logical_id') == id }
        raise ArgumentError, "逻辑标识重复：#{id}"
      end
      width, depth, height = whd.map(&:mm)
      group = entities.add_group
      group.name = name
      group.set_attribute(DICTIONARY, 'logical_id', id)
      group.layer = entities.model.layers[0]
      face = group.entities.add_face([0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0])
      raise "无法建立底面：#{name}" unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      group.transformation = Geom::Transformation.translation(xyz.map(&:mm))
      # Surface assignment, not painting the parent container.
      group.entities.each do |entity|
        entity.layer = entities.model.layers[0]
        entity.material = material if material && entity.is_a?(Sketchup::Face)
      end
      group
    end

    # For an unrotated box in its own local coordinate frame only.
    # Use a target height rather than scaling the complete object or accumulating
    # floating-point increments. Existing faces remain editable SketchUp geometry.
    def grow_to_mm(group, height)
      target = Float(height)
      raise ArgumentError, '目标高度必须大于零且为有限数值' unless target.finite? && target.positive?
      raise ContextError, '待生长构件已失效或被锁定' unless group.valid? && !group.locked?
      faces = group.entities.grep(Sketchup::Face)
      top = faces.select { |face| face.normal.z > 0.999 }.max_by { |face| face.bounds.center.z }
      raise ContextError, '找不到水平顶面；此辅助函数仅适用于竖直盒体' unless top
      base = faces.map { |face| face.bounds.min.z }.min
      delta = target.mm - (top.bounds.center.z - base)
      raise ArgumentError, '生长目标低于现有高度；缩短请使用局部改稿流程' if delta < -1.0e-7
      top.pushpull(delta) if delta > 1.0e-7
      group
    end

    def vector(values, name, positive:)
      raise ArgumentError, "#{name} 必须包含三个数值" unless values.is_a?(Array) && values.length == 3
      numbers = values.map { |n| Float(n) }
      unless numbers.all? { |n| n.finite? && (!positive || n.positive?) }
        raise ArgumentError, "#{name} 包含无效尺寸"
      end
      numbers
    end
  end
end
