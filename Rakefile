require "bundler/gem_tasks"
require "rake/testtask"
require 'yard'
require 'yard/rake/yardoc_task'

task :default

if ENV['TEST_DISABLE_GUI'] == '1'
    has_gui = false
else
    has_gui = begin
                  require 'Qt'
                  true
              rescue LoadError
                  false
              end
end

Rake::TestTask.new(:test) do |t|
    t.libs << "."
    t.libs << "lib"
    test_files = FileList['test/**/test_*.rb']
    if RUBY_ENGINE != 'ruby'
        test_files = test_files.exclude("test/app/test_debug.rb")
    end
    if !has_gui
        test_files = test_files.exclude("test/test_gui.rb")
    end
    t.test_files = test_files
    t.warning = false
end

begin
    require 'coveralls/rake/task'
    Coveralls::RakeTask.new
    task 'test:coveralls' => ['test', 'coveralls:push']
rescue LoadError
end

# For backward compatibility with some scripts that expected hoe
task :gem => :build

UIFILES = %w{gui/relations_view/relations.ui gui/relations_view/relations_view.ui gui/stepping.ui}
desc 'generate all Qt UI files using rbuic4'
task :uic do
    rbuic = 'rbuic4'
    if File.exists?('/usr/lib/kde4/bin/rbuic4')
        rbuic = '/usr/lib/kde4/bin/rbuic4'
    end

    UIFILES.each do |file|
        file = 'lib/roby/' + file
        if !system(rbuic, '-o', file.gsub(/\.ui$/, '_ui.rb'), file)
            STDERR.puts "Failed to generate #{file}"
        end
    end
end
task :compile => :uic

YARD::Rake::YardocTask.new
task :doc => :yard
