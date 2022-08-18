# frozen_string_literal: true

class ViewModel::Registry
  include Singleton

  DEFERRED_NAME = Object.new

  class << self
    delegate :for_view_name, :register, :default_view_name, :infer_model_class_name,
             :clear_removed_classes!, :all, :roots,
             to: :instance
  end

  def initialize
    @lock = Monitor.new
    @viewmodel_classes_by_name = {}
    @viewmodel_classes_by_name_and_version = {}
    @deferred_viewmodel_classes = []
  end

  def for_view_name(name, version: nil)
    raise ViewModel::DeserializationError::InvalidSyntax.new('ViewModel name cannot be nil') if name.nil?

    @lock.synchronize do
      # Resolve names for any deferred viewmodel classes
      resolve_deferred_classes

      viewmodel_class =
        if version
          versions_for_name = @viewmodel_classes_by_name_and_version.fetch(name) do
            raise ViewModel::DeserializationError::UnknownView.new(name)
          end
          versions_for_name.fetch(version) do
            raise ViewModel::Migration::NoSuchVersionError.new(@viewmodel_classes_by_name, version)
          end
        else
          @viewmodel_classes_by_name.fetch(name) do
            raise ViewModel::DeserializationError::UnknownView.new(name)
          end
        end

      unless viewmodel_class < ViewModel
        raise RuntimeError.new("Internal registry error, registered '#{name}' is not a viewmodel: #{viewmodel_class.inspect}")
      end

      viewmodel_class
    end
  end

  def all
    @lock.synchronize do
      resolve_deferred_classes
      @viewmodel_classes_by_name.values
    end
  end

  def roots
    all.select { |c| c.root? }
  end

  def register(viewmodel, as: DEFERRED_NAME)
    @lock.synchronize do
      @deferred_viewmodel_classes << [viewmodel, as]
    end
  end

  def default_view_name(model_class_name)
    model_class_name.gsub('::', '.')
  end

  def infer_model_class_name(view_name)
    view_name.gsub('.', '::')
  end

  # For Rails hot code loading: ditch any classes that are not longer present at
  # their constant
  def clear_removed_classes!
    @lock.synchronize do
      resolve_deferred_classes
      @viewmodel_classes_by_name.delete_if do |_name, klass|
        !Kernel.const_defined?(klass.name) || Kernel.const_get(klass.name) != klass
      end
      @viewmodel_classes_by_name_and_version.each_value do |versions|
        versions.delete_if do |_version, klass|
          !Kernel.const_defined?(klass.name) || Kernel.const_get(klass.name) != klass
        end
      end
    end
  end

  private

  def resolve_deferred_classes
    until @deferred_viewmodel_classes.empty?
      vm, view_name = @deferred_viewmodel_classes.pop
      next unless vm.should_register?

      view_name = vm.view_name if view_name == DEFERRED_NAME

      if (prev_vm = @viewmodel_classes_by_name[view_name]) && prev_vm != vm
        raise RuntimeError.new(
                'No two viewmodel classes may have the same name: ' \
                "#{vm.name} and #{prev_vm.name} named #{view_name}")
      end

      @viewmodel_classes_by_name[view_name] = vm

      # Migratable views record their previous names. Other views have only the
      # current version.
      versioned_view_names =
        if vm.respond_to?(:versioned_view_names)
          vm.versioned_view_names
        else
          { vm.schema_version => vm.view_name }
        end

      versioned_view_names.each do |previous_version, previous_name|
        versions_for_name = (@viewmodel_classes_by_name_and_version[previous_name] ||= {})

        if (prev_vm = versions_for_name[previous_version]) && prev_vm != vm
          # By recording the name/version pairs in this global registry, we're
          # promising that a given (name, version) is always resolvable to a
          # single viewmodel. This results in the constraint that there can
          # never be two viewmodels that had the same name at the same version:
          # if renaming a viewmodel would cause such a conflict, it is necessary
          # to 'jump' schema versions at the same time as renaming to ensure
          # there is no ambiguity.
          raise RuntimeError.new(
                  'No two viewmodel classes may have the same name at the same version: ' \
                  "#{vm.name} and #{prev_vm.name} named #{previous_name} at #{previous_version}")
        end

        versions_for_name[previous_version] = vm
      end
    end
  end
end
