# frozen_string_literal: true
# coding: utf-8

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'iknow_view_models/version'

Gem::Specification.new do |spec|
  spec.name          = "iknow_view_models"
  spec.version       = IknowViewModels::VERSION
  spec.authors       = ["iKnow Team"]
  spec.email         = ["edge@iknow.jp"]
  spec.summary       = "ViewModels provide a means of encapsulating a collection of related data and specifying its JSON serialization."
  spec.description   = ""
  spec.homepage      = "https://github.com/iknow/cerego_view_models"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 5.0"
  spec.add_dependency "activesupport", ">= 5.0"

  spec.add_dependency "acts_as_manual_list"
  spec.add_dependency "deep_preloader"
  spec.add_dependency "iknow_cache"
  spec.add_dependency "iknow_params", "~> 2.2.0"
  spec.add_dependency "safe_values"
  spec.add_dependency "keyword_builder"

  spec.add_dependency "concurrent-ruby"
  spec.add_dependency "jbuilder"
  spec.add_dependency "json_schema"
  spec.add_dependency "lazily"
  spec.add_dependency "renum"

  spec.add_development_dependency "appraisal"
  spec.add_development_dependency "bundler"
  spec.add_development_dependency "byebug"
  spec.add_development_dependency "method_source"
  spec.add_development_dependency "minitest-hooks"
  spec.add_development_dependency "pg", '~> 0.18' # As of 5.1.4, Rails runtime check excludes pg 1.x, see #31669
  spec.add_development_dependency "pry"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec-expectations"
  spec.add_development_dependency "sqlite3"
end
