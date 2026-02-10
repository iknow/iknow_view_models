# frozen_string_literal: true

require 'bundler/setup'

require 'minitest'
Minitest.load_plugins

require 'minitest/hooks/default'
require 'minitest/hooks/test'
require 'minitest/mock'
require 'minitest/reporters'
require 'minitest/reporters/junit_reporter'

require 'rspec/expectations'
require 'rspec/expectations/minitest_integration'

FileUtils.mkdir_p('test/reports')
Minitest::Reporters.use!(
  [
    Minitest::Reporters::DefaultReporter.new,
    Minitest::Reporters::JUnitReporter.new(
      'test/reports',
      single_file: false,
    ),
  ],
)

require 'minitest/autorun'
