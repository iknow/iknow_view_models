# frozen_string_literal: true

class ViewModel::Record::AttributeData
  attr_reader :name, :model_attr_name, :attribute_viewmodel, :attribute_serializer

  def initialize(name:,
                 model_attr_name:,
                 attribute_viewmodel:,
                 attribute_serializer:,
                 array:,
                 read_only:,
                 write_once:)
    @name                 = name
    @model_attr_name      = model_attr_name
    @attribute_viewmodel  = attribute_viewmodel
    @attribute_serializer = attribute_serializer
    @array                = array
    @read_only            = read_only
    @write_once           = write_once
  end

  def association?
    false
  end

  def array?
    @array
  end

  def read_only?
    @read_only
  end

  def write_once?
    @write_once
  end

  def using_serializer?
    !@attribute_serializer.nil?
  end

  def using_viewmodel?
    !@attribute_viewmodel.nil?
  end

  def map_value(value)
    if array?
      value.map { |v| yield(v) }
    else
      yield(value)
    end
  end
end
