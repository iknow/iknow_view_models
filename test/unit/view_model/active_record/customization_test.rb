# coding: utf-8
require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"


require 'renum'

class ViewModel::ActiveRecord::SpecializeAssociationTest < ActiveSupport::TestCase
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

        def self.pre_parse_translations(viewmodel_reference, hash, translations)
          raise "type check" unless translations.is_a?(Hash) && translations.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
          hash["translations"] = translations.map { |lang, text| { '$type' => "Translation", "language" => lang, "translation" => text } }
        end

        def resolve_translations(update_datas, previous_translation_views)
          existing = previous_translation_views.index_by { |x| [x.model.language, x.model.translation] }
          update_datas.map do |update_data|
            existing.fetch([update_data["language"], update_data["translation"]]) { TranslationView.for_new_model }
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
    super

    @text1 = Text.create(text: "dog",
                    translations: [Translation.new(language: "ja", translation: "犬"),
                                   Translation.new(language: "fr", translation: "chien")])

    @text1_view = {
      "id"           => @text1.id,
      '$type'        => "Text",
      '$version'     => 1,
      "text"         => "dog",
      "translations" => {
        "ja" => "犬",
        "fr" => "chien"
      }
    }

    enable_logging!
  end

  def test_serialize
    assert_equal(@text1_view, serialize(TextView.new(@text1)))
  end

  def test_create
    create_view = @text1_view.dup.tap {|v| v.delete('id')}
    new_text_view = TextView.deserialize_from_view(create_view)
    new_text_model = new_text_view.model

    assert_equal('dog', new_text_model.text)

    new_translations = new_text_model.translations.map do |x|
      [x['language'], x['translation']]
    end
    assert_equal([%w(fr chien),
                  %w(ja 犬)],
                 new_translations.sort)
  end

  def test_noop
    original_translation_models = @text1.translations.order(:id).to_a
    alter_by_view!(TextView, @text1) {}
    assert_equal(original_translation_models, @text1.translations.order(:id).to_a)
  end
end

class ViewModel::ActiveRecord::FlattenAssociationTest < ActiveSupport::TestCase
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
      Quiz(QuizSectionView)
      Vocab(VocabSectionView)

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
          members.merge('$type' => viewmodel.view_name)
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
        association :section_data, viewmodels: [VocabSectionView, QuizSectionView]

        def self.pre_parse(viewmodel_reference, user_data)
          section_type_name = user_data.delete("section_type")
          section_type = SectionType.with_name(section_type_name)
          raise "Invalid section type: #{section_type_name.inspect}" unless section_type

          user_data["section_data"] = section_type.construct_hash(user_data.slice!(*self._members.keys))
        end

        def resolve_section_data(update_data, previous_translation_view)
          # Reuse if it's the same type
          if update_data.viewmodel_class == previous_translation_view.class
            previous_translation_view
          else
            update_data.viewmodel_class.for_new_model
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
    super

    @simplesection = Section.create(name: "simple1")
    @simplesection_view = {
      "id"           => @simplesection.id,
      '$type'        => "Section",
      '$version'     => 1,
      "section_type" => "Simple",
      "name"         => "simple1"
    }

    @quizsection = Section.create(name: "quiz1", section_data: QuizSection.new(quiz_name: "qq"))
    @quizsection_view = {
      "id"           => @quizsection.id,
      '$type'        => "Section",
      '$version'     => 1,
      "section_type" => "Quiz",
      "name"         => "quiz1",
      "quiz_name"    => "qq"
    }

    @vocabsection = Section.create(name: "vocab1", section_data: VocabSection.new(vocab_word: "dog"))
    @vocabsection_view = {
      "id"           => @vocabsection.id,
      '$type'        => "Section",
      '$version'     => 1,
      "section_type" => "Vocab",
      "name"         => "vocab1",
      "vocab_word"   => "dog"
    }

    enable_logging!
  end

  def test_serialize
    v = SectionView.new(@simplesection)
    assert_equal(@simplesection_view, v.to_hash)

    v = SectionView.new(@quizsection)
    assert_equal(@quizsection_view, v.to_hash)

    v = SectionView.new(@vocabsection)
    assert_equal(@vocabsection_view, v.to_hash)
  end

  def new_view_like(view)
    view.dup.tap { |v| v.delete('id') }
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

    v = SectionView.deserialize_from_view(new_view_like(@simplesection_view))
    assert_section.call(v.model, "simple1")

    v = SectionView.deserialize_from_view(new_view_like(@quizsection_view))
    assert_section.call(v.model, "quiz1") do |m|
      assert(m.is_a?(QuizSection))
      assert_equal("qq", m.quiz_name)
    end

    v = SectionView.deserialize_from_view(new_view_like(@vocabsection_view))
    assert_section.call(v.model, "vocab1") do |m|
      assert(m.is_a?(VocabSection))
      assert_equal("dog", m.vocab_word)
    end
  end

  def test_noop
    # Simple sections have no stability worth checking

    old_quizsection_data = @quizsection.section_data
    alter_by_view!(SectionView, @quizsection) {}
    assert_equal(old_quizsection_data, @quizsection.section_data)

    old_vocabsection_data = @vocabsection.section_data
    alter_by_view!(SectionView, @vocabsection) {}
    assert_equal(old_vocabsection_data, @vocabsection.section_data)
  end
end
