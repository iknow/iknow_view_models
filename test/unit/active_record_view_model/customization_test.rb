# coding: utf-8
require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"


require 'renum'

class ActiveRecordViewModel::SpecializeAssociationTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Text) do
      define_schema do |t|
        t.string :text
      end

      define_model do
        has_many :translations, dependent: :destroy, inverse_of: :text
      end

      define_viewmodel do
        attributes :text
        association :translations

        def self.pre_parse_translations(user_data)
          raise "type check" unless user_data.is_a?(Hash) && user_data.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
          user_data.map { |lang, text| { "_type" => "Translation", "language" => lang, "translation" => text } }
        end

        def self.resolve_translations(update_datas, previous_translation_views)
          existing = previous_translation_views.index_by { |x| [x.model.language, x.model.translation] }
          update_datas.map do |update_data|
            existing.fetch([update["lang"], update["translation"]]) { Views::Translation.new }
          end
        end

        def serialize_translations(json, serialize_context:)
          translation_views = self.translations
          json.translations do
            translation_views.each do |tv|
              json.set!(tv.language, tv.translation)
            end
          end
        end
      end
    end

    build_viewmodel(:translation) do
      define_schema do |t|
        t.references :text
        t.string :language
        t.string :translation
      end

      define_model do
        belongs_to :text, inverse_of: :translations
      end

      define_viewmodel do
        attributes :language, :translation
      end
    end
  end

  def setup
    @text1 = Text.create(text: "dog",
                    translations: [Translation.new(language: "ja", translation: "犬"),
                                   Translation.new(language: "fr", translation: "chien")])

    @textview1 = {
      "id"    => @text1.id,
      "_type" => "Text",
      "text"  => "dog",
      "translations" => {
        "ja" => "犬",
        "fr" => "chien"
      }
    }
  end

  def test_serialize
    tv = Views::Text.new(@text1)
    assert_equal(@textview1, tv.to_hash)
  end

  def test_create
    tv = Views::Text.deserialize_from_view(@textview1)
    t = tv.model

    assert(!t.changed?)
    assert(!t.new_record?)

    assert_equal("dog", t.text)

    assert_equal(2, t.translations.count)
    t.translations.order(:id).each do |c|
      assert(!c.changed?)
      assert(!c.new_record?)
      assert(@textview1["translations"].has_key?(c.language))
      assert_equal(@textview1["translations"][c.language], c.translation)
    end
  end
end

class ActiveRecordViewModel::FlattenAssociationTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:QuizSection) do
      define_schema do |t|
        t.string :quiz_name
      end
      define_model do
        has_one :section, as: :section_data
      end
      define_viewmodel do
        attributes :quiz_name
      end
    end

    build_viewmodel(:VocabSection) do
      define_schema do |t|
        t.string :vocab_word
      end
      define_model do
        has_one :section, as: :section_data
      end
      define_viewmodel do
        attributes :vocab_word
      end
    end

    # define a `renum` enumeration
    Object.enum :SectionType do
      Simple(nil)
      Quiz(Views::QuizSection)
      Vocab(Views::VocabSection)

      attr_reader :viewmodel
      def init(viewmodel)
        @viewmodel = viewmodel
      end

      def construct_hash(members)
        case self
        when SectionType::Simple
          raise "nopes" if members.present?
          nil
        else
          members.merge("_type" => viewmodel.view_name)
        end
      end

      def self.for_viewmodel(viewmodel)
        @vm_index ||= SectionType.values.index_by(&:viewmodel)
        vm_class = viewmodel.try(:class)
        @vm_index.fetch(vm_class)
      end
    end

    build_viewmodel(:Section) do
      define_schema do |t|
        t.string :name
        t.references :section_data
        t.string :section_data_type
      end

      define_model do
        belongs_to :section_data, polymorphic: :true, dependent: :destroy
      end

      define_viewmodel do
        attributes :name
        association :section_data, viewmodels: [Views::VocabSection, Views::QuizSection]

        def self.pre_parse(user_data)
          section_type = SectionType.with_name(user_data["section_type"])
          raise "Invalid section type: #{user_data["section_type"].inspect}" unless section_type

          user_data.delete("section_type")
          user_data["section_data"] = section_type.construct_hash(user_data.slice!(*self._members.keys))

          user_data
        end

        def self.resolve_section_data(update_data, previous_translation_view)
          # Reuse if it's the same type
          if update_data.viewmodel_class == previous_translation_view.class
            previous_translation_view
          else
            update_data.viewmodel_class.new
          end
        end

        def serialize_section_data(json, serialize_context:)
          sd_view = self.section_data
          section_type = SectionType.for_viewmodel(sd_view)

          json.section_type section_type.name
          if sd_view
            sd_view.serialize_members(json, serialize_context: serialize_context)
          end
        end
      end
    end

  end

  def setup
    @simplesection = Section.create(name: "simple1")
    @simplesection_view = {
      "id"           => @simplesection.id,
      "_type"        => "Section",
      "section_type" => "Simple",
      "name"         => "simple1"
    }

    @quizsection = Section.create(name: "quiz1", section_data: QuizSection.new(quiz_name: "qq"))
    @quizsection_view = {
      "id"           => @quizsection.id,
      "_type"        => "Section",
      "section_type" => "Quiz",
      "name"         => "quiz1",
      "quiz_name"    => "qq"
    }

    @vocabsection = Section.create(name: "vocab1", section_data: VocabSection.new(vocab_word: "dog"))
    @vocabsection_view = {
      "id"           => @vocabsection.id,
      "_type"        => "Section",
      "section_type" => "Vocab",
      "name"         => "vocab1",
      "vocab_word"   => "dog"
    }
  end

  def test_serialize
    v = Views::Section.new(@simplesection)
    assert_equal(@simplesection_view, v.to_hash)

    v = Views::Section.new(@quizsection)
    assert_equal(@quizsection_view, v.to_hash)

    v = Views::Section.new(@vocabsection)
    assert_equal(@vocabsection_view, v.to_hash)
  end

  def test_create
    assert_section = ->(model, name, &check_section){
      assert(!model.changed?)
      assert(!model.new_record?)
      assert_equal(name, model.name)

      sd = model.section_data
      if check_section
        assert(sd)
        assert(!sd.changed?)
        assert(!sd.new_record?)
        check_section.call(sd)
      else
        assert_nil(sd)
      end
    }

    v = Views::Section.deserialize_from_view(@simplesection_view)
    assert_section.call(v.model, "simple1")

    v = Views::Section.deserialize_from_view(@quizsection_view)
    assert_section.call(v.model, "quiz1") do |m|
      assert(m.is_a?(QuizSection))
      assert_equal("qq", m.quiz_name)
    end

    v = Views::Section.deserialize_from_view(@vocabsection_view)
    assert_section.call(v.model, "vocab1") do |m|
      assert(m.is_a?(VocabSection))
      assert_equal("dog", m.vocab_word)
    end
  end
end
