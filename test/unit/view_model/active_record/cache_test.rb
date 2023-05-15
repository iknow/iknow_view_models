# frozen_string_literal: true

require "minitest/autorun"
require "minitest/unit"
require "minitest/hooks"

require_relative "../../../helpers/arvm_test_models.rb"
require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/viewmodel_spec_helpers.rb"

require "view_model"
require "view_model/active_record"

# IknowCache uses Rails.cache: create a dummy cache.

DUMMY_RAILS_CACHE = ActiveSupport::Cache::MemoryStore.new

IknowCache.configure! do
  logger ::ActiveRecord::Base.logger
  cache DUMMY_RAILS_CACHE
end

class ViewModel::ActiveRecord
  class CacheTest < ActiveSupport::TestCase
    using ViewModel::Utils::Collections
    extend Minitest::Spec::DSL
    include ARVMTestUtilities

    # Defines a cacheable parent Model with a owned Child and a cachable shared Shared.
    module CacheableParentAndChildren
      extend ActiveSupport::Concern
      include ViewModelSpecHelpers::ParentAndBelongsToChild

      def model_attributes
        super.merge(
          schema:    ->(t) { t.references :shared, foreign_key: true },
          model:     ->(_) { belongs_to :shared, inverse_of: :models },
          viewmodel: ->(_) {
            association :shared, shared: true, optional: false
            cacheable!
          }
        )
      end

      def shared_cache_group
        @shared_cache_group ||= IknowCache.register_group(:shared, :id)
      end

      def shared_viewmodel_class
        shared_cache_group = self.shared_cache_group
        @shared_viewmodel_class ||= define_viewmodel_class(:Shared, namespace: namespace) do
          define_schema do |t|
            t.string :name
          end

          define_model do
            has_many :models
          end

          define_viewmodel do
            attributes :name
            cacheable!(cache_group: shared_cache_group)
          end
        end
      end

      def shared_model_class
        shared_viewmodel_class.model_class
      end

      # parent depends on children, ensure it's touched first
      def viewmodel_class
        shared_viewmodel_class
        super
      end

      included do
        let(:shared)     { shared_model_class.create!(name: "shared1") }
        let(:root)       { model_class.create!(name: "root1", child: Child.new(name: "owned1"), shared: shared) }
        let(:root_view)  { viewmodel_class.new(root) }
      end
    end

    before(:each) do
      DUMMY_RAILS_CACHE.clear
    end

    # Extract the iKnowCaches to verify their contents
    def read_cache(viewmodel_class, id)
      vm_cache = viewmodel_class.viewmodel_cache
      vm_cache.send(:cache).read(vm_cache.key_for(id))
    end

    def serialize_from_database
      view    = viewmodel_class.new(model_class.find(root.id))
      context = viewmodel_class.new_serialize_context
      data    = ViewModel.serialize_to_hash([view], serialize_context: context)
      refs    = context.serialize_references_to_hash
      [data, refs]
    end

    def parse_result(result)
      data_json, refs_json = result
      data                 = data_json.map { |d| JSON.parse(d) }
      refs                 = refs_json.transform_values { |v| JSON.parse(v) }
      [data, refs]
    end

    def fetch_with_cache
      viewmodel_class.viewmodel_cache.fetch([root.id])
    end

    def serialize_with_cache
      parse_result(fetch_with_cache)
    end

    module BehavesLikeACache
      extend ActiveSupport::Concern
      included do
        it 'returns the right serialization' do
          value(serialize_with_cache).must_equal(serialize_from_database)
        end

        it 'returns the right serialization after caching' do
          fetch_with_cache
          value(serialize_from_database).must_equal(serialize_with_cache)
        end

        it 'writes to the cache after fetching' do
          cached_value = read_cache(viewmodel_class, root.id)
          value(cached_value).wont_be(:present?)

          fetch_with_cache

          cached_value = read_cache(viewmodel_class, root.id)
          value(cached_value).must_be(:present?)
        end

        it 'saves the returned serialization in the cache' do
          data, refs = fetch_with_cache
          value(data.size).must_equal(1)

          cached_root = read_cache(viewmodel_class, root.id)
          value(cached_root).must_be(:present?)
          value(cached_root[:data]).must_equal(data.first)

          ref_cache = cached_root[:ref_cache]
          value(refs.size).must_equal(ref_cache.size)

          refs.each do |key, ref_data|
            view_name, id = ref_cache[key]
            value(view_name).must_be(:present?)
            value(id).must_be(:present?)

            # The cached reference must correspond to the returned data.
            parsed_data = JSON.parse(ref_data)
            value(parsed_data["id"]).must_equal(id)
            value(parsed_data["_type"]).must_equal(view_name)

            # When the cached reference is to independently cached data
            # (SharedView in this test), make sure that data is correctly
            # cached.
            next unless view_name == "Shared"
            value(id).must_equal(shared.id)
            cached_shared = read_cache(shared_viewmodel_class, id)
            value(cached_shared).must_be(:present?)
            value(cached_shared[:data]).must_equal(ref_data)
            value(cached_shared[:ref_cache]).must_be(:blank?)
          end
        end
      end
    end

    describe 'with owned and shared children' do
      include CacheableParentAndChildren
      include BehavesLikeACache

      describe 'with a record in the cache' do
        # Fetch the root record to ensure it's in the cache
        before(:each) do
          viewmodel_class.viewmodel_cache.fetch([root.id])
        end

        def change_in_database
          root.update_attribute(:name, "CHANGEDROOT")
          shared.update_attribute(:name, "CHANGEDSHARED")
        end

        it 'resolves from the cache' do
          before_data, before_refs = serialize_from_database
          change_in_database

          cache_data, cache_refs = serialize_with_cache
          value(cache_data).must_equal(before_data)
          value(cache_refs).must_equal(before_refs)
        end

        it 'can clear the root cache' do
          _before_data, before_refs = serialize_from_database
          change_in_database
          viewmodel_class.viewmodel_cache.clear

          cache_data, cache_refs = serialize_with_cache
          value(cache_data[0]["name"]).must_equal("CHANGEDROOT") # Root view invalidated
          value(cache_refs).must_equal(before_refs) # Shared view not invalidated
        end

        describe 'when deserializing' do
          it 'does not clear the cache on round-trip' do
            alter_by_view!(viewmodel_class, root) {}

            cached_root_value = read_cache(viewmodel_class, root.id)
            value(cached_root_value).must_be(:present?)

            cached_root_value = read_cache(shared_viewmodel_class, shared.id)
            value(cached_root_value).must_be(:present?)
          end

          it 'clears only the root cache on edit to root' do
            alter_by_view!(viewmodel_class, root) do |data, _refs|
              data['name'] = 'new name'
            end

            cached_root_value = read_cache(viewmodel_class, root.id)
            value(cached_root_value).wont_be(:present?)

            cached_root_value = read_cache(shared_viewmodel_class, shared.id)
            value(cached_root_value).must_be(:present?)
          end

          it 'clears only the root cache on edit to owned child' do
            alter_by_view!(viewmodel_class, root) do |data, _refs|
              data['child']['name'] = 'new child name'
            end

            cached_root_value = read_cache(viewmodel_class, root.id)
            value(cached_root_value).wont_be(:present?)

            cached_root_value = read_cache(shared_viewmodel_class, shared.id)
            value(cached_root_value).must_be(:present?)
          end

          it 'clears only the shared child cache on edit to shared child' do
            alter_by_view!(viewmodel_class, root) do |_data, refs|
              refs.values.first['name'] = 'new shared name'
            end

            cached_root_value = read_cache(viewmodel_class, root.id)
            value(cached_root_value).must_be(:present?)

            cached_root_value = read_cache(shared_viewmodel_class, shared.id)
            value(cached_root_value).wont_be(:present?)
          end
        end

        it 'can delete an entity from a cache' do
          _before_data, before_refs = serialize_from_database
          change_in_database
          viewmodel_class.viewmodel_cache.delete(root.id)

          cache_data, cache_refs = serialize_with_cache
          value(cache_data[0]["name"]).must_equal("CHANGEDROOT")
          value(cache_refs).must_equal(before_refs)
        end

        it 'can clear a referenced cache' do
          change_in_database
          shared_viewmodel_class.viewmodel_cache.clear

          # Shared view invalidated, but root view not
          cache_data, cache_hrefs = serialize_with_cache
          value(cache_data[0]["name"]).must_equal("root1")
          value(cache_hrefs.values[0]["name"]).must_equal("CHANGEDSHARED")
        end

        it 'can clear a cache via its external cache group' do
          change_in_database
          shared_cache_group.invalidate_cache_group

          # Shared view invalidated, but root view not
          cache_data, cache_hrefs = serialize_with_cache
          value(cache_data[0]["name"]).must_equal("root1")
          value(cache_hrefs.values[0]["name"]).must_equal("CHANGEDSHARED")
        end

        describe 'and a record not in the cache' do
          let(:root2) { model_class.create!(name: "root2", child: Child.new(name: "owned2"), shared: shared) }

          def serialize_from_database
            views   = model_class.find(root.id, root2.id).map { |r| viewmodel_class.new(r) }
            context = viewmodel_class.new_serialize_context
            data    = ViewModel.serialize_to_hash(views, serialize_context: context)
            refs    = context.serialize_references_to_hash
            [data, refs]
          end

          def fetch_with_cache
            viewmodel_class.viewmodel_cache.fetch([root.id, root2.id])
          end

          it 'merges matching shared references between cache hits and misses' do
            db_data, db_refs = serialize_from_database
            value(db_refs.size).must_equal(1)

            cache_data, cache_refs = serialize_with_cache
            value(cache_data).must_equal(db_data)
            value(cache_refs).must_equal(db_refs)
          end

          it 'merges cache hits and misses' do
            _, refs = serialize_from_database
            change_in_database

            cache_data, cache_refs = serialize_with_cache
            value(cache_data[0]["name"]).must_equal("root1")
            value(cache_data[1]["name"]).must_equal("root2")
            value(cache_refs).must_equal(refs)
          end
        end
      end
    end

    describe "with a non-cacheable shared child" do
      include ViewModelSpecHelpers::ParentAndSharedChild
      def model_attributes
        super.merge(viewmodel: ->(_) { cacheable! })
      end

      let(:root)       { model_class.create!(name: "root1", child: Child.new(name: "owned1")) }
      let(:root_view)  { viewmodel_class.new(root) }

      include BehavesLikeACache
    end

    describe 'when fetched by viewmodel' do
      def fetch_with_cache
        viewmodel_class.viewmodel_cache.fetch_by_viewmodel([root_view])
      end

      include CacheableParentAndChildren
      include BehavesLikeACache

      it 'can handle duplicates' do
        data, _refs = viewmodel_class.viewmodel_cache.fetch_by_viewmodel([root_view, root_view])
        value(data.size).must_equal(2)
        value(data[0]).must_equal(data[1])
      end
    end
  end
end
