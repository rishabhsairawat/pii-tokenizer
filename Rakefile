require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'appraisal'

RSpec::Core::RakeTask.new(:spec)

# Default task now runs specs against all Rails versions
task :default do
  if ENV['APPRAISAL_INITIALIZED'] || ENV['TRAVIS']
    Rake::Task['spec'].invoke
  else
    Rake::Task['appraisal'].invoke
  end
end

# Task to run the Rails 4 specs
task :rails4 do
  sh 'bundle exec appraisal rails-4.2 rspec'
end

# Task to run the Rails 5 specs
task :rails5 do
  sh 'bundle exec appraisal rails-5.2 rspec'
end

# Task to run all Rails versions
task all_rails: %i[rails4 rails5]
