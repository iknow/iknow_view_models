# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cerego_view_models/version'

Gem::Specification.new do |spec|
  spec.name          = "cerego_view_models"
  spec.version       = CeregoViewModels::VERSION
  spec.authors       = ["Cerego"]
  spec.email         = ["edge@cerego.com"]
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
  spec.add_dependency "cerego_active_record_patches"

  spec.add_development_dependency "bundler", "~> 1.6"
  spec.add_development_dependency "rake"

  spec.add_development_dependency "sqlite3"

  spec.add_development_dependency "byebug"

  spec.add_dependency "jbuilder", "~> 2.2.5"

end
