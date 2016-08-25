# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'iknow_view_models/version'

Gem::Specification.new do |spec|
  spec.name          = "iknow_view_models"
  spec.version       = IknowViewModels::VERSION
  spec.authors       = ["iKnow Team"]
  spec.email         = ["edge@iknow.jp"]
  spec.summary       = %q{ViewModels provide a means of encapsulating a collection of related data and specifying its JSON serialization.}
  spec.description   = %q{}
  spec.homepage      = ""
  spec.license       = "Proprietary"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord"
  spec.add_dependency "activesupport"
  spec.add_dependency "iknow_params"
  spec.add_dependency "cerego_active_record_patches"
  spec.add_dependency "acts_as_manual_list"
  spec.add_dependency "deep_preloader"

  spec.add_dependency "lazily"
  spec.add_dependency "renum"
  spec.add_dependency "concurrent-ruby"
  spec.add_dependency "json_schema"

  spec.add_development_dependency "bundler", "~> 1.6"
  spec.add_development_dependency "rake"

  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "pg"

  spec.add_development_dependency "byebug"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "method_source"
  spec.add_development_dependency "appraisal"

  spec.add_development_dependency "minitest-hooks"

  spec.add_dependency "jbuilder", "~> 2.5.0"

end