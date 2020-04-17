# frozen_string_literal: true

require "yard"
require "yard/rake/yardoc_task"
require "roby/app/rake"

task :default

Roby.app.load_base_config
Roby::App::Rake::TestTask.new

task "test" => "rubocop" if Roby::App::Rake.define_rubocop_if_enabled

YARD::Rake::YardocTask.new do |yard|
    yard.files = ["models/**/*.rb", "lib/**/*.rb"]
end
desc "Generate YARD documentation (alias for 'yard')"
task "doc" => "yard"
