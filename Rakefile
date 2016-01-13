require "bundler/gem_tasks"
require "rake/testtask"

task :default
Rake::TestTask.new(:test) do |t|
    t.libs << "."
    t.libs << "lib"
    t.test_files = FileList['test/suite_core.rb']
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

###########
# Documentation generation
#
# This redefines Hoe's targets for documentation, as the documentation
# generation is not flexible enough for us

# This is for the user's guide
begin
    require 'roby/app/rake'
    require 'webgen/webgentask'

    namespace 'doc' do
        Webgen::WebgenTask.new('guide') do |website|
            website.clobber_outdir = true
            website.directory = File.join(Dir.pwd, 'doc', 'guide')
            website.config_block = lambda do |config|
                config['output'] = ['Webgen::Output::FileSystem', File.join(Dir.pwd, 'doc', 'html')]
            end
        end

        def plugins_documentation_generation(target_prefix)
            task "plugins_#{target_prefix}docs" do
                Roby::Rake.invoke_plugin_target("#{target_prefix}docs")
            end
        end
        desc 'generate all documentation'
        task 'all' => ['doc:guide', 'doc:api']
        desc 'removes all documentation'
        task 'clobber' do
            FileUtils.rm_rf File.join('doc', 'html')
        end

        desc 'regenerate all documentation'
        task 'redocs' do
            FileUtils.rm_f File.join('doc', 'guide', 'webgen.cache')
            FileUtils.rm_rf File.join('doc', 'html')
            if !system('rake', 'doc:all')
                raise "failed to regenerate documentation"
            end
        end
    end
    task 'redocs' => 'doc:redocs'
    task 'clobber_docs' => 'doc:clobber'

rescue LoadError => e
    STDERR.puts "a required gem seems to be not available, documentation generation disabled"
    STDERR.puts "  Ruby reported the following load error: #{e.message}"
end

