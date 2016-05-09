require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
  t.warning = true
  t.verbose = true
end

desc "Open an IRB console with the test helpers"
task :test_console do
  ruby %q{-Ilib  -e 'load "test/helpers/test_models.rb"' -r irb -e 'IRB.start(__FILE__)'}
end

desc "Open a Pry console with the test helpers"
task 'test_console:pry' do
  ruby %q{-Ilib  -e 'load "test/helpers/test_models.rb"' -r pry -e 'Pry.start'}
end
